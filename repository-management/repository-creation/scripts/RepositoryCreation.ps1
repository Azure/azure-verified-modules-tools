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
        Invoke-AvmProcess -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $Directory `
            -EnvVars @{ GH_HOST = 'github.com'; GH_DEBUG = $null; GH_PROMPT_DISABLED = '1' }
    } $executable $ArgumentList $WorkingDirectory
}

function Get-AvmRepositoryDefaultRulesetProperty {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo] $AuthoringModule,

        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $response = Invoke-AvmRepositoryCreationProcess -AuthoringModule $AuthoringModule -Tool gh `
        -WorkingDirectory $WorkingDirectory -ArgumentList @(
            'api', '--hostname', 'github.com', '--method', 'GET',
            '--header', 'X-GitHub-Api-Version: 2022-11-28', "repos/$Repository/properties/values"
        )
    $properties = ConvertFrom-Json -InputObject $response.StdOut -AsHashtable -NoEnumerate
    if ($properties -isnot [array]) {
        throw [System.IO.InvalidDataException]::new("GitHub returned invalid custom properties for $Repository.")
    }
    $matching = @($properties | Where-Object { $_.property_name -ceq 'rulesets-default-opt-in' })
    if ($matching.Count -gt 1) {
        throw [System.IO.InvalidDataException]::new("GitHub returned duplicate default-ruleset properties for $Repository.")
    }
    $value = if ($matching.Count -eq 1) { $matching[0].value } else { $null }
    if ($null -ne $value -and ($value -isnot [string] -or $value -cnotin @('true', 'false'))) {
        throw [System.IO.InvalidDataException]::new("GitHub returned an invalid rulesets-default-opt-in value for $Repository.")
    }
    return [pscustomobject]@{ Value = $value }
}

function Set-AvmRepositoryDefaultRulesetProperty {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo] $AuthoringModule,

        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Value
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($null -ne $Value -and ($Value -isnot [string] -or $Value -cnotin @('true', 'false'))) {
        throw [System.ArgumentException]::new('rulesets-default-opt-in must be the string true, false, or null to reset it.')
    }
    $valueDescription = if ($null -eq $Value) { 'inherited (null)' } else { $Value }
    if (-not $PSCmdlet.ShouldProcess($Repository, "Set rulesets-default-opt-in to $valueDescription")) {
        return
    }
    $arguments = @(
        'api', '--hostname', 'github.com', '--method', 'PATCH',
        '--header', 'X-GitHub-Api-Version: 2022-11-28', "repos/$Repository/properties/values",
        '--raw-field', 'properties[][property_name]=rulesets-default-opt-in'
    )
    $arguments += if ($null -eq $Value) {
        @('--field', 'properties[][value]=null')
    } else {
        @('--raw-field', "properties[][value]=$Value")
    }
    $null = Invoke-AvmRepositoryCreationProcess -AuthoringModule $AuthoringModule -Tool gh `
        -WorkingDirectory $WorkingDirectory -ArgumentList $arguments
    $current = Get-AvmRepositoryDefaultRulesetProperty -AuthoringModule $AuthoringModule `
        -Repository $Repository -WorkingDirectory $WorkingDirectory
    if ($current.Value -cne $Value) {
        throw [System.InvalidOperationException]::new(
            "Could not verify rulesets-default-opt-in=$valueDescription for $Repository."
        )
    }
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
    if ($PlanOnly -or -not $PSCmdlet.ShouldProcess($repository, 'Initialize metadata and publish the new repository with a temporary default-ruleset opt-out')) {
        return [pscustomobject]@{
            Status = 'plan'
            RepositoryUrl = $repositoryUrl
            Metadata = $validation.Metadata
            InitialPush = [pscustomobject]@{
                Branch = 'main'
                TemporaryRulesetProperty = 'rulesets-default-opt-in'
                RestoreOriginalValue = $true
            }
        }
    }

    $process = @{ AuthoringModule = $AuthoringModule }
    $null = Invoke-AvmRepositoryCreationProcess @process -Tool gh -ArgumentList @('auth', 'status')
    $stagingRoot = Join-Path $workRoot ([guid]::NewGuid().ToString('N'))
    $modulePath = Join-Path $stagingRoot $RepositoryName
    $repositoryCreated = $false
    $initialPushCompleted = $false
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
        $propertyParameters = @{
            AuthoringModule = $AuthoringModule
            Repository = $repository
            WorkingDirectory = $modulePath
        }
        $originalProperty = Get-AvmRepositoryDefaultRulesetProperty @propertyParameters
        $restoreProperty = $originalProperty.Value -cne 'false'
        $publicationError = $null
        $recoveryPath = Join-Path $stagingRoot 'ruleset-recovery.json'
        $recovery = [ordered]@{
            repository = $repository
            propertyName = 'rulesets-default-opt-in'
            value = $originalProperty.Value
        }
        [System.IO.File]::WriteAllText(
            $recoveryPath,
            ($recovery | ConvertTo-Json).Replace("`r`n", "`n") + "`n", [System.Text.UTF8Encoding]::new($false)
        )
        try {
            if ($restoreProperty) {
                Set-AvmRepositoryDefaultRulesetProperty @propertyParameters -Value 'false' -Confirm:$false
            }
            $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('push', '--set-upstream', 'origin', 'HEAD:refs/heads/main')
            $initialPushCompleted = $true
        }
        catch {
            $publicationError = $_
        }
        finally {
            if ($restoreProperty) {
                try {
                    Set-AvmRepositoryDefaultRulesetProperty @propertyParameters -Value $originalProperty.Value -Confirm:$false
                }
                catch {
                    $failures = @($_.Exception)
                    if ($null -ne $publicationError) {
                        $failures = @($publicationError.Exception) + $failures
                    }
                    throw [System.AggregateException]::new(
                        "Default-ruleset restoration failed for $repository. Restore rulesets-default-opt-in using '$recoveryPath' before retrying.",
                        [System.Exception[]]$failures
                    )
                }
            }
        }
        if ($null -ne $publicationError) {
            throw $publicationError
        }
        $published = $true
        return [pscustomobject]@{
            Status = 'pass'
            RepositoryUrl = $repositoryUrl
            Metadata = $initialized.Metadata
        }
    }
    catch {
        $state = if ($initialPushCompleted) {
            "The initial commit was pushed to $repositoryUrl, but repository setup did not complete."
        }
        elseif ($repositoryCreated) {
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
