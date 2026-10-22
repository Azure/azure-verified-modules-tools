. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot '..' '..' 'repository-management' 'shared' 'TestTenant.ps1')

function Get-AvmWorkflowCompilerAdapters {
    [CmdletBinding()]
    param()

    return @{
        ToolResolver = {
            param([string] $Name, [string] $Path)
            Get-AvmTool -Name $Name -Path $Path -SkipModuleVersionCheck
        }
        ToolInstaller = {
            param([string] $Name, [string] $Path)
            Install-AvmTool -Name $Name -Path $Path -SkipModuleVersionCheck -Confirm:$false
        }
        ProcessInvoker = {
            param([string] $FilePath, [string[]] $ArgumentList, [string] $WorkingDirectory)
            Invoke-AvmWorkflowProcess -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
        }
    }
}

function Get-AvmWorkflowModuleIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [AllowEmptyString()] [string] $ModuleClientIds,
        [AllowEmptyString()] [string] $TenantId
    )

    try {
        $mapping = ConvertFrom-AvmTestTenantJson -Json $ModuleClientIds
        $null = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $mapping
    }
    catch {
        throw [ArgumentException]::new("VALIDATE_MODULE_CLIENT_IDS: $($_.Exception.Message)", $_.Exception)
    }
    $parsedTenant = [guid]::Empty
    if (-not [guid]::TryParseExact($TenantId, 'D', [ref] $parsedTenant) -or $parsedTenant -eq [guid]::Empty) {
        throw [ArgumentException]::new('VALIDATE_TENANT_ID: TenantId must be a nonempty GUID.')
    }
    $identity = Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepWorkflowModuleIdentityInternal -Parameters $PSBoundParameters
    return @{
        moduleRoot = $identity.ModuleRoot; clientId = $identity.ClientId; tenantId = $identity.TenantId; identityKey = $identity.IdentityKey
    }
}

function Select-AvmWorkflowSubscription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $Example,
        [AllowEmptyString()] [string] $PoolJson,
        [AllowEmptyString()] [string] $FallbackSubscriptionId,
        [ValidateRange(0, 2147483647)] [int] $RandomSeed = 0,
        [ValidateRange(0, 2147483647)] [int] $CaseIndex = 0
    )

    return Invoke-AvmWorkflowPackagePrivate -Name Select-AvmBicepWorkflowDeploymentSubscriptionInternal -Parameters $PSBoundParameters
}

function Test-AvmWorkflowLegacyModuleLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [Collections.IDictionary] $Template)

    return Invoke-AvmWorkflowPackagePrivate -Name Test-AvmBicepWorkflowLegacyModuleLockInternal -Parameters $PSBoundParameters
}

function Get-AvmWorkflowNamePrefix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('isolated', 'shared', 'fallback')] [string] $IsolationMode,
        [AllowEmptyString()] [string] $Prefix
    )

    return Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepWorkflowNamePrefixInternal -Parameters $PSBoundParameters
}

function Get-AvmWorkflowCompiledTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TestPath
    )

    $parameters = @{} + $PSBoundParameters
    foreach ($entry in (Get-AvmWorkflowCompilerAdapters).GetEnumerator()) {
        $parameters[$entry.Key] = $entry.Value
    }
    return Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepWorkflowCompiledTestInternal -Parameters $parameters
}

function Assert-AvmWorkflowIsolationInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('isolated', 'shared', 'fallback')] [string] $IsolationMode,
        [Parameter(Mandatory)] [string] $CompiledTemplate,
        [bool] $RemoveDeployment = $true
    )

    return Invoke-AvmWorkflowPackagePrivate -Name Assert-AvmBicepWorkflowIsolationInputInternal -Parameters $PSBoundParameters
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

    if ([string]::IsNullOrEmpty($CompiledTemplate)) {
        $CompiledTemplate = Get-AvmWorkflowCompiledTest -Root $Root -ModulePath $ModulePath -TestPath $TestPath
    }
    if ([string]::IsNullOrEmpty($FallbackGroup)) {
        $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes(([guid]$SubscriptionId).ToString('D')))).ToLowerInvariant()
        $FallbackGroup = "avm-deploy-$($ModulePath.Replace('\', '/').Trim('/').ToLowerInvariant())-$key"
    }
    $isolation = Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepWorkflowIsolationInternal -Parameters @{
        Root = $Root; ModulePath = $ModulePath; TestPath = $TestPath; TenantId = $TenantId; SubscriptionId = $SubscriptionId
        CompiledTemplate = $CompiledTemplate; FallbackGroup = $FallbackGroup
    }
    $result = [ordered]@{}
    foreach ($property in $isolation.PSObject.Properties) {
        $result[$property.Name.Substring(0, 1).ToLowerInvariant() + $property.Name.Substring(1)] = $property.Value
    }
    return $result
}

function Get-AvmWorkflowDeploymentMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $TestFiles,
        [string] $PoolJson,
        [string] $FallbackSubscriptionId,
        [string] $ModuleClientIds,
        [string] $TenantId,
        [ValidateRange(0, 2147483647)] [int] $RandomSeed = 0,
        [switch] $DisplaySubscriptionNames
    )

    $active = @($TestFiles | Where-Object { -not (ConvertTo-AvmWorkflowBoolean -Value $_.e2eIgnore -AllowEmpty) })
    if ($active.Count -gt 0) {
        $null = Get-AvmWorkflowModuleIdentity -Root $Root -ModulePath $ModulePath `
            -ModuleClientIds $ModuleClientIds -TenantId $TenantId
    }
    $parameters = @{} + $PSBoundParameters
    foreach ($entry in (Get-AvmWorkflowCompilerAdapters).GetEnumerator()) {
        $parameters[$entry.Key] = $entry.Value
    }
    $matrix = @(Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepE2eDeploymentMatrixInternal -Parameters $parameters | ForEach-Object {
            if ($_.IsolationMode -eq 'fallback') {
                Write-Warning "$($_.Path): $($_.IsolationDiagnostic)"
            }
            $record = [ordered]@{}
            foreach ($property in $_.PSObject.Properties) {
                $record[$property.Name.Substring(0, 1).ToLowerInvariant() + $property.Name.Substring(1)] = $property.Value
            }
            $record
        })
    return @{ deploymentMatrix = ConvertTo-Json -InputObject $matrix -Depth 10 -Compress; sharedScope = 'false' }
}

function Get-AvmWorkflowAuthentication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [Collections.IDictionary] $TestCase,
        [string] $PoolJson,
        [string] $FallbackSubscriptionId,
        [string] $ModuleClientIds,
        [string] $TenantId
    )

    $null = Get-AvmWorkflowModuleIdentity -Root $Root -ModulePath $ModulePath `
        -ModuleClientIds $ModuleClientIds -TenantId $TenantId
    $parameters = @{} + $PSBoundParameters
    foreach ($entry in (Get-AvmWorkflowCompilerAdapters).GetEnumerator()) {
        $parameters[$entry.Key] = $entry.Value
    }
    $context = Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepE2eTestContextInternal -Parameters $parameters
    return @{
        subscriptionId = $context.SubscriptionId; tenantId = $context.TenantId; clientId = $context.ClientId
        modulePath = $context.ModulePath; example = $context.Example
    }
}

function Confirm-AvmWorkflowAzureContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $ClientId
    )

    $context = Get-AzContext -ErrorAction Stop
    $tenant = [guid]::Empty
    $configured = [guid]::Empty
    if ($null -eq $context -or $context.Subscription.Id -ine $SubscriptionId -or
        -not [guid]::TryParseExact($context.Tenant.Id, 'D', [ref]$tenant) -or $tenant -eq [guid]::Empty -or
        -not [guid]::TryParseExact($TenantId, 'D', [ref]$configured) -or $configured -ne $tenant -or
        $context.Account.Id -ine $ClientId -or $context.Account.Type -ine 'ServicePrincipal' -or
        $context.Environment.Name -cne 'AzureCloud') {
        throw [InvalidOperationException]::new('The Azure PowerShell context does not match the selected module client, tenant, subscription and cloud.')
    }
    return $tenant.ToString('D')
}
