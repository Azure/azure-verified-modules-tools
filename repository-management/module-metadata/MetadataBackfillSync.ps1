. (Join-Path $PSScriptRoot 'MetadataBackfill.ps1')

function Assert-AvmMetadataBackfillTrigger {
    if ($env:GITHUB_EVENT_NAME -and $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch') {
        throw [System.InvalidOperationException]::new('Metadata backfill is manual-only; scheduled and repository_dispatch runs cannot enable it.')
    }
}

function Get-AvmMetadataBackfillActor {
    return [pscustomobject]@{ login = 'azure-verified-modules[bot]'; id = 187664033; type = 'Bot' }
}

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
    $moduleId = $Matches.id
    $moduleType = @{ res = 'resource'; ptn = 'pattern'; utl = 'utility' }[$Matches.kind]
    $toolsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Assert-AvmMetadataBackfillCapability
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
    $matching = @($records | Where-Object { $_['ModuleName'] -ceq $moduleId -or $_['RepoURL'] -ceq "https://github.com/$orgAndRepoName" })
    if ($matching.Count -eq 0) {
        $localIndex = Join-Path $toolsRoot 'repository-management' 'repository-sync' 'config' 'repository-metadata.csv'
        $records += @(ConvertFrom-AvmMetadataIndex -Content (Get-Content -LiteralPath $localIndex -Raw) |
                Where-Object { $_['moduleId'] -ceq $moduleId })
    }
    return @{
        LegacyRecord = $records
        SourceSha = $source.sha
        ScriptPath = Join-Path $PSScriptRoot 'Invoke-ModuleMetadataBackfill.ps1'
    }
}

function Get-AvmMetadataBackfillReview {
    param([string] $orgAndRepoName, [string] $branchName)

    $reviews = @(Invoke-RepositoryGitHub -AsJson -Arguments @(
            'pr', 'list', "--repo=$orgAndRepoName", '--state=open', "--head=$branchName", '--json=number,url'
        ))
    if ($reviews.Count -gt 0) {
        return @{ Exists = $true; Reason = "An open metadata backfill review already exists: $($reviews[0].url)" }
    }
    $head = Get-RepositoryBranchHead -Repository $orgAndRepoName -Branch $branchName
    if ($head) {
        return @{ Exists = $true; Reason = "Backfill branch '$branchName' already exists; it will not be overwritten." }
    }
    return @{ Exists = $false; Reason = '' }
}

function Invoke-AvmMetadataBackfillPreparation {
    param([Parameter(Mandatory)][hashtable] $Context)

    $backfill = $Context.State.BackfillContext
    $result = & $backfill.ScriptPath -RepositoryRoot $Context.Root `
        -Repository $Context.Repository.full_name -Ecosystem terraform -LegacyRecord $backfill.LegacyRecord `
        -UpdateSource:$Context.State.UpdateSource -Confirm:$false
    if ($result.Status -cne 'pass') {
        throw [System.InvalidOperationException]::new("Metadata file creation returned '$($result.Status)'.")
    }
    return $result
}
