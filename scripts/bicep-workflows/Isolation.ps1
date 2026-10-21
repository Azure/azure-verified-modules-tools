. (Join-Path $PSScriptRoot 'Common.ps1')

function Test-AvmWorkflowLegacyModuleLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [Collections.IDictionary] $Template)

    $resources = @(if ($Template['resources'] -is [Collections.IDictionary]) {
            $Template.resources.Values
        }
        else { $Template['resources'] | Where-Object { $null -ne $_ } })
    if ($resources.Count -gt 0 -and $Template['$schema'] -match '/(?:managementGroup|tenant)DeploymentTemplate\.json#?$') {
        return $true
    }
    foreach ($resource in $resources) {
        if ($resource -isnot [Collections.IDictionary]) {
            throw [ArgumentException]::new('Compiled deployment resources must be objects.')
        }
        if ($resource['type'] -ieq 'Microsoft.Resources/deployments') {
            $properties = $resource['properties']
            if ($properties -isnot [Collections.IDictionary]) {
                throw [ArgumentException]::new('Compiled nested deployments must have properties.')
            }
            if ($properties['templateLink']) { return $true }
            $nested = $properties['template']
            if ($nested -is [string] -and $nested -cmatch "^\[variables\('([^']+)'\)\]$" -and
                $Template['variables'] -is [Collections.IDictionary]) {
                $nested = $Template['variables'][$Matches[1]]
            }
            if ($nested -isnot [Collections.IDictionary]) { return $true }
            if (Test-AvmWorkflowLegacyModuleLock -Template $nested) { return $true }
        }
        if ($resource['resources'] -and (Test-AvmWorkflowLegacyModuleLock -Template @{ resources = $resource.resources })) {
            return $true
        }
    }
    return $false
}

function Get-AvmWorkflowNamePrefix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('isolated', 'shared', 'fallback')] [string] $IsolationMode,
        [AllowEmptyString()] [string] $Prefix
    )

    if ($IsolationMode -eq 'fallback') { return '' }
    if ([string]::IsNullOrEmpty($Prefix)) { $Prefix = 'gci' }
    if ($Prefix -cnotmatch '^[a-z][a-z0-9]{0,2}$') {
        throw [ArgumentException]::new('Reviewed Bicep tests require a lowercase alphanumeric naming prefix of one to three characters.')
    }
    return $Prefix + '#_avmE2eSuffix_#'
}

function Assert-AvmWorkflowIsolationInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('isolated', 'shared', 'fallback')] [string] $IsolationMode,
        [Parameter(Mandatory)] [string] $CompiledTemplate,
        [bool] $RemoveDeployment = $true
    )

    if ($IsolationMode -eq 'fallback') { return }
    if ($IsolationMode -eq 'shared' -and -not $RemoveDeployment) {
        throw [ArgumentException]::new('Shared-target execution requires cleanup before releasing the lifecycle lock; removeDeployment must be true.')
    }
    $template = ConvertFrom-Json -InputObject $CompiledTemplate -AsHashtable
    $package = Get-Module Avm.Authoring | Select-Object -First 1
    & $package {
        param($Template)
        $ci = Get-AvmBicepWorkflowEnvironment -Enabled
        if (@($ci.Tokens.Keys | Where-Object { $_ -ine 'namePrefix' }).Count -gt 0) {
            throw [ArgumentException]::new('Reviewed isolation does not allow custom localToken overrides. Use native scope/location inputs or retain fallback serialization.')
        }
        if (-not [string]::IsNullOrEmpty($ci.KeyVaultName)) {
            throw [ArgumentException]::new('Reviewed isolation does not allow implicit CI Key Vault parameter overrides. Use an explicitly reviewed fixture or retain fallback serialization.')
        }
        $parameters = @{}
        if ($Template['parameters'] -is [Collections.IDictionary]) {
            foreach ($name in $Template['parameters'].Keys) { $parameters[$name] = @{ type = 'secureString' } }
        }
        $overrides = Get-AvmBicepCiParameter -TemplateParameters $parameters -Variables $ci.Variables -Secrets $ci.Secrets
        if ($overrides.Count -gt 0) {
            throw [ArgumentException]::new('Reviewed isolation does not allow CI parameter overrides of compiled test defaults. Remove the overrides or retain fallback serialization.')
        }
    } $template
}

function Get-AvmWorkflowIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TestPath,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [string] $CompiledTemplate,
        [string] $OwnerPath,
        [string] $FallbackGroup
    )

    $hashText = {
        param([string] $Value)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant()
    }
    $casePath = Resolve-AvmWorkflowPath -Root $Root -RelativePath "$ModulePath/$TestPath"
    $directory = Split-Path -Parent $casePath
    $manifestPath = Join-Path $directory 'isolation.json'
    if ([string]::IsNullOrEmpty($CompiledTemplate)) {
        $CompiledTemplate = Get-AvmWorkflowCompiledTest -Root $Root -ModulePath $ModulePath -TestPath $TestPath
    }
    if (-not $FallbackGroup) {
        $FallbackGroup = 'avm-deploy-' + $ModulePath.Replace('\', '/').Trim('/').ToLowerInvariant() +
            '-' + (& $hashText (([guid]$SubscriptionId).ToString('D')))
    }
    $fallback = @{
        isolationMode = 'fallback'
        concurrencyGroup = $FallbackGroup
        fallbackModuleLock = Test-AvmWorkflowLegacyModuleLock -Template (ConvertFrom-Json -InputObject $CompiledTemplate -AsHashtable)
        isolationDiagnostic = 'Isolation is not established: no case-local isolation.json. Retaining legacy fallback serialization, not claiming ownership.'
    }
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $fallback }
    $relativeManifest = [IO.Path]::GetRelativePath($Root, $manifestPath).Replace('\', '/')
    $manifestPath = Resolve-AvmWorkflowPath -Root $Root -RelativePath $relativeManifest
    $file = Get-Item -LiteralPath $manifestPath
    if ($file.PSIsContainer -or $file.Name -cne 'isolation.json' -or $file.Length -gt 65536) {
        throw [ArgumentException]::new('Isolation evidence must be an exact-case regular isolation.json file of at most 64 KiB.')
    }
    $contract = ConvertFrom-AvmTestTenantJson -Json ([IO.File]::ReadAllText($manifestPath))
    if ($contract -isnot [Collections.IDictionary] -or
        @($contract.Keys | Where-Object { $_ -cnotin @('version', 'evidence', 'sharedTarget') }).Count -gt 0 -or
        ($contract['version'] -isnot [long] -and $contract['version'] -isnot [int]) -or $contract['version'] -ne 1 -or
        $contract['evidence'] -isnot [Collections.IDictionary] -or $contract['evidence'].Count -ne 4) {
        throw [ArgumentException]::new('Isolation requires version 1 and four reviewed ownership evidence fields.')
    }
    foreach ($name in @('resources', 'cleanup', 'sharedState', 'identity')) {
        $value = $contract['evidence'][$name]
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 4096) {
            throw [ArgumentException]::new("Isolation evidence must explain '$name'.")
        }
    }
    $target = $contract['sharedTarget']
    if ($null -ne $target -and ($target -isnot [string] -or
            $target -notmatch '^/(?:subscriptions/|providers/)[A-Za-z0-9_()./#-]+$' -or
            $target.EndsWith('/') -or $target.Contains('//') -or $target.Split('/') -contains '..')) {
        throw [ArgumentException]::new('sharedTarget must identify one absolute ARM resource or singleton setting, optionally using #_subscriptionId_#.')
    }
    if ($null -ne $target) {
        $target = $target.Replace('#_subscriptionId_#', ([guid]$SubscriptionId).ToString('D'))
        if ($target.Contains('#')) {
            throw [ArgumentException]::new('sharedTarget contains an unsupported token; use the exact shared target, not a module or scope class.')
        }
    }
    if (-not (Get-Command Invoke-AvmTestE2e).Parameters.ContainsKey('RequireResourceIsolation')) {
        throw [InvalidOperationException]::new('Reviewed isolation requires a qualified native package with RequireResourceIsolation. The current package cannot unlock this case.')
    }
    $package = Get-Module Avm.Authoring | Select-Object -First 1
    if (-not $OwnerPath) { $OwnerPath = $ModulePath }
    $owner = Resolve-AvmWorkflowPath -Root $Root -RelativePath $OwnerPath
    $ownership = & $package {
        param($Content, $Owner)
        $template = ConvertFrom-AvmStrictJson -Json $Content
        try {
            $context = [pscustomobject]@{ Root = $Owner; Ecosystem = 'bicep' }
            foreach ($kind in @('Feature', 'Provider')) {
                if (@(Get-AvmContextRequiredRegistration -Context $context -Kind $kind).Count -gt 0) {
                    throw [AvmConfigurationException]::new('Shared feature/provider registration settings have no established isolation boundary.')
                }
            }
            @{ Boundary = Assert-AvmBicepResourceIsolationTemplate -Template $template; Diagnostic = '' }
        }
        catch [AvmConfigurationException] { @{ Boundary = ''; Diagnostic = $_.Exception.Message } }
    } $CompiledTemplate $owner
    if (-not $ownership.Boundary -or (Test-Path -LiteralPath (Join-Path $directory 'post.ps1'))) {
        $fallback.isolationDiagnostic = 'Isolation ownership is not established: ' +
            $(if ($ownership.Diagnostic) { $ownership.Diagnostic } else { 'Arbitrary post hooks have no enforced ownership boundary.' }) +
            ' Retaining legacy fallback serialization.'
        return $fallback
    }
    $group = 'avm-deploy-isolated-' + [guid]::NewGuid().ToString('N')
    $mode = 'isolated'
    if ($null -ne $target) {
        $mode = 'shared'
        $group = 'avm-deploy-target-' + (& $hashText ("azurecloud|$TenantId|$target".ToLowerInvariant()))
    }
    return @{
        isolationMode = $mode
        isolationBoundary = $ownership.Boundary
        concurrencyGroup = $group
        isolationDiagnostic = if ($mode -eq 'shared') { 'Reviewed isolation with an explicit shared-target lifecycle lock.' } else { 'Reviewed resource and cleanup isolation: no serialization lock required.' }
    }
}

function Get-AvmWorkflowCompiledTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TestPath
    )

    $module = Resolve-AvmWorkflowPath -Root $Root -RelativePath $ModulePath
    $tool = Get-AvmTool -Name bicep -Path $module -SkipModuleVersionCheck
    if ($tool.Status -ceq 'not-installed') {
        $null = Install-AvmTool -Name bicep -Path $module -SkipModuleVersionCheck -Confirm:$false
        $tool = Get-AvmTool -Name bicep -Path $module -SkipModuleVersionCheck
    }
    if ($tool.Status -cne 'installed') { throw [InvalidOperationException]::new('The managed Bicep compiler is not installed.') }
    $path = Resolve-AvmWorkflowPath -Root $Root -RelativePath "$ModulePath/$TestPath"
    $result = Invoke-AvmWorkflowProcess -FilePath $tool.Path -ArgumentList @('build', $path, '--stdout') -WorkingDirectory $Root
    $template = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable
    if ($template -isnot [Collections.IDictionary]) { throw [ArgumentException]::new('The compiled test must be an ARM template object.') }
    return [string]$result.StdOut
}
