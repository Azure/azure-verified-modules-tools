#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][hashtable] $Context)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function ConvertFrom-AvmMetadataIndex {
    param([Parameter(Mandatory)][string] $Content)

    foreach ($row in ConvertFrom-Csv -InputObject $Content) {
        $record = @{}
        foreach ($property in $row.PSObject.Properties) { $record[$property.Name] = $property.Value }
        $record
    }
}

function Get-AvmRepositoryMetadataBackfillContext {
    param([Parameter(Mandatory)][string] $orgAndRepoName)

    if ($orgAndRepoName -cnotmatch '^Azure/terraform-(azurerm|azapi|azure)-(?<id>avm-(?<kind>res|ptn|utl)-[a-z0-9-]+)$') {
        throw [System.ArgumentException]::new('Metadata backfill requires a supported Azure Terraform module repository.')
    }
    $moduleType = @{ res = 'resource'; ptn = 'pattern'; utl = 'utility' }[$Matches.kind]
    $toolsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $toolsRoot 'repository-management' 'module-catalog' 'scripts' 'ModuleCatalog.ps1')
    $configuration = Read-AvmCatalogConfiguration
    $index = @($configuration.outputs | Where-Object {
            $_.kind -ceq 'csv' -and $_.ecosystem -ceq 'terraform' -and $_.moduleType -ceq $moduleType
        })[0]
    $source = Invoke-RepositoryGitHubApi -Endpoint "repos/$($configuration.repositories.docs)/commits/main"
    if ($source.sha -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.IO.InvalidDataException]::new('The metadata index commit is missing or invalid.')
    }
    $file = Get-RepositoryFileAtCommit -Repository $configuration.repositories.docs -Path $index.sourcePath -Sha $source.sha
    $records = @(ConvertFrom-AvmMetadataIndex -Content $file.Content)
    return @{
        LegacyRecord = $records
        SourceSha = $source.sha
    }
}

if ($env:GITHUB_EVENT_NAME -and $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch') {
    throw [System.InvalidOperationException]::new('Metadata backfill is manual-only; scheduled and repository_dispatch runs cannot enable it.')
}
if (-not $PSCmdlet.ShouldProcess($Context.Root, 'Create missing metadata in the temporary repository checkout')) {
    return
}
$backfill = Get-AvmRepositoryMetadataBackfillContext -orgAndRepoName $Context.Repository.full_name
Write-Host "$($Context.Repository.full_name) - preparing metadata from index commit $($backfill.SourceSha)."
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-metadata-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
try {
    $inputPath = Join-Path $temporary 'input.json'
    $outputPath = Join-Path $temporary 'result.json'
    $inputData = @{
        RepositoryRoot = $Context.Root
        Repository = $Context.Repository.full_name
        LegacyRecord = $backfill.LegacyRecord
    }
    [System.IO.File]::WriteAllText($inputPath, (ConvertTo-Json -InputObject $inputData -Depth 64), [System.Text.UTF8Encoding]::new($false))
    $executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $worker = Join-Path $PSScriptRoot 'Invoke-ModuleMetadataBackfillWorker.ps1'
    $process = Invoke-RepositorySyncProcess -Command $executable -Arguments @(
        '-NoProfile', '-NonInteractive', '-File', $worker, '-InputPath', $inputPath, '-OutputPath', $outputPath
    ) -WorkingDirectory $Context.Root -EnvVars @{ AVM_OFFLINE = '1'; GH_TOKEN = $null }
    if (-not [string]::IsNullOrWhiteSpace($process.StdOut)) {
        Write-Information -MessageData $process.StdOut -InformationAction Continue
    }
    if ($process.ExitCode -ne 0) {
        throw [System.InvalidOperationException]::new("Metadata preparation failed (exit $($process.ExitCode)): $($process.StdErr)")
    }
    if (-not [string]::IsNullOrWhiteSpace($process.StdErr)) { Write-Warning $process.StdErr }
    $result = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    if ($result -isnot [System.Collections.IDictionary] -or $result['Status'] -cne 'pass') {
        throw [System.InvalidOperationException]::new('Metadata preparation did not return one successful result.')
    }
    return $result
}
finally {
    try { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction Stop }
    catch { Write-Warning "Failed to clean up metadata preparation files at $temporary : $($_.Exception.Message)" }
}
