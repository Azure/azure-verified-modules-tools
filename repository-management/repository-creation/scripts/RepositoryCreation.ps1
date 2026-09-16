#Requires -Version 7.4

function Import-AvmRepositoryCreationModule {
    [CmdletBinding()]
    param()

    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    $manifest = Join-Path $moduleRoot 'Avm.Authoring.psd1'
    $module = Import-Module -Name $manifest -Scope Local -Force -PassThru -ErrorAction Stop
    foreach ($command in @('Initialize-AvmModuleMetadata', 'Test-AvmModuleMetadata')) {
        if (-not $module.ExportedCommands.ContainsKey($command)) {
            throw [System.InvalidOperationException]::new("The checked-out Avm.Authoring module must export $command.")
        }
    }
    return $module
}

function New-AvmRepositoryMetadataInput {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo] $AuthoringModule,

        [string] $ModuleDisplayName,
        [string] $ModuleDescription,
        [string] $CanonicalType,
        [string] $TelemetryIdPrefix,
        [string[]] $OwnerGitHubHandles = @(),
        [string] $OwnerTeam,
        [string[]] $AlternativeNames = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    foreach ($field in @('ModuleDisplayName', 'ModuleDescription', 'CanonicalType')) {
        if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $field -ValueOnly))) {
            throw [System.ArgumentException]::new("$field must be supplied explicitly for repository creation.")
        }
    }
    $schemaPath = Join-Path $AuthoringModule.ModuleBase 'Resources' 'Schemas' 'v1' 'avm-module-metadata.schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable
    $metadata = [ordered]@{
        '$schema' = $schema.'$id'
        moduleDisplayName = $ModuleDisplayName
        moduleDescription = $ModuleDescription
        canonicalType = $CanonicalType
        owners = @($OwnerGitHubHandles)
    }
    if (-not [string]::IsNullOrEmpty($TelemetryIdPrefix)) {
        $metadata.telemetryIdPrefix = $TelemetryIdPrefix
    }
    if (-not [string]::IsNullOrEmpty($OwnerTeam)) {
        $metadata.owners += $OwnerTeam
    }
    if ($AlternativeNames.Count -gt 0) {
        $metadata.alternativeNames = $AlternativeNames
    }
    return $metadata
}

function Invoke-AvmRepositoryCreationProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo] $AuthoringModule,

        [Parameter(Mandatory)]
        [ValidateSet('git', 'gh')]
        [string] $Tool,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [string] $WorkingDirectory = $PWD.Path
    )

    $executable = (Get-Command -Name $Tool -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    & $AuthoringModule {
        param($Executable, $Arguments, $Directory)
        Invoke-AvmProcess -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $Directory
    } $executable $ArgumentList $WorkingDirectory
}

function New-AvmRepositoryContent {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo] $AuthoringModule,

        [Parameter(Mandatory)]
        [ValidatePattern('^terraform-[a-z0-9-]+-avm-(res|ptn|utl)-[a-z-]+$')]
        [string] $RepositoryName,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Metadata,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [string] $WorkPath = (Join-Path $PWD.Path 'out' 'repository-creation'),

        [switch] $PlanOnly
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $repository = "Azure/$RepositoryName"
    $repositoryUrl = "https://github.com/$repository"
    $workRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkPath)
    $validation = & $AuthoringModule.ExportedCommands['Test-AvmModuleMetadata'] `
        -Path $workRoot -InputObject $Metadata -Ecosystem terraform -ModuleType $ModuleType -SkipModuleVersionCheck
    if ($validation.Status -ne 'pass') {
        throw [System.ArgumentException]::new("Invalid repository metadata: $($validation.Issues.Message -join ' ')")
    }
    if ($PlanOnly -or -not $PSCmdlet.ShouldProcess($repository, 'Initialize module metadata and publish the new repository')) {
        return [pscustomobject]@{
            Status = 'plan'
            RepositoryUrl = $repositoryUrl
            Metadata = $validation.Metadata
        }
    }

    $process = @{ AuthoringModule = $AuthoringModule }
    $null = Invoke-AvmRepositoryCreationProcess @process -Tool gh -ArgumentList @('auth', 'status')
    $stagingRoot = Join-Path $workRoot ([guid]::NewGuid().ToString('N'))
    $modulePath = Join-Path $stagingRoot $RepositoryName
    $repositoryCreated = $false
    $published = $false
    try {
        $null = New-Item -ItemType Directory -Path $stagingRoot -Force
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @(
            'clone', '--quiet', '--depth', '1', '--single-branch',
            'https://github.com/Azure/terraform-azurerm-avm-template.git', $modulePath
        )
        $initialized = & $AuthoringModule.ExportedCommands['Initialize-AvmModuleMetadata'] `
            -Path $modulePath -InputObject $Metadata -Ecosystem terraform -ModuleType $ModuleType `
            -SkipModuleVersionCheck -Confirm:$false
        if ($initialized.Status -ne 'pass' -or -not (Test-Path -LiteralPath (Join-Path $modulePath 'metadata.json') -PathType Leaf)) {
            throw [System.InvalidOperationException]::new('Module metadata initialization did not produce a valid metadata.json.')
        }

        # The template is a private staging checkout; publish a fresh history
        # whose first commit already contains the validated metadata file.
        Remove-Item -LiteralPath (Join-Path $modulePath '.git') -Recurse -Force
        $process.WorkingDirectory = $modulePath
        # Git's init-db alias stays distinct from the Terraform init upgrade guard.
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('init-db', '--quiet', '--initial-branch=main')
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('add', '--all')
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('add', '--force', '--', 'metadata.json')
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('commit', '--quiet', '-m', 'chore: initialize module repository')
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('remote', 'add', 'origin', "$repositoryUrl.git")
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool gh -ArgumentList @('repo', 'create', $repository, '--public')
        $repositoryCreated = $true
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('push', '--set-upstream', 'origin', 'HEAD:refs/heads/main')
        $published = $true
        return [pscustomobject]@{
            Status = 'pass'
            RepositoryUrl = $repositoryUrl
            Metadata = $initialized.Metadata
        }
    }
    catch {
        $state = if ($repositoryCreated) {
            "The repository was created at $repositoryUrl but initial publication failed. It has not been deleted."
        }
        else {
            'Repository creation did not complete; no files were pushed by this script.'
        }
        throw [System.InvalidOperationException]::new(
            "$state Inspect the retained staging directory '$stagingRoot' before retrying. $($_.Exception.Message)",
            $_.Exception
        )
    }
    finally {
        if ($published) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        }
    }
}
