function Get-AvmBicepE2eTestContext {
    <#
    .SYNOPSIS
        Revalidate one selected Bicep E2E case and return its execution context.

    .DESCRIPTION
        Revalidates the selected module identity, tenant, subscription pool
        ordering, exact owning module, and isolation evidence before returning
        the explicit values a caller passes to Invoke-AvmTestE2e. It performs no
        sign-in, Azure call, deployment, cleanup, or artifact write.

    .PARAMETER Root
        Existing filesystem repository root.
    .PARAMETER ModulePath
        Exact repository-relative module selected for the workflow leg.
    .PARAMETER TestCase
        One record previously returned by Get-AvmBicepE2eDeploymentMatrix.
    .PARAMETER PoolJson
        Optional native test subscription pool JSON.
    .PARAMETER FallbackSubscriptionId
        General-only fallback subscription when PoolJson is empty.
    .PARAMETER ModuleClientIds
        Required JSON object mapping canonical module roots to client GUIDs.
    .PARAMETER TenantId
        Required nonempty tenant GUID.
    .PARAMETER NamePrefix
        Optional one-to-three-character lowercase prefix for reviewed isolated
        execution. Fallback execution uses no prefix.
    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery version check for source or offline callers.
    .OUTPUTS
        PSCustomObject with SubscriptionId, TenantId, ClientId, ModulePath,
        Example, NamePrefix, ArtifactKey, IsolationMode, ConcurrencyGroup, and
        RequireResourceIsolation.
    .EXAMPLE
        PS> Get-AvmBicepE2eTestContext -Root $repo -ModulePath $module -TestCase $matrix[0] -FallbackSubscriptionId $subscription -ModuleClientIds $mapping -TenantId $tenant
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ModulePath,
        [Parameter(Mandatory)] [object] $TestCase,
        [AllowEmptyString()] [string] $PoolJson,
        [AllowEmptyString()] [string] $FallbackSubscriptionId,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ModuleClientIds,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $TenantId,
        [AllowEmptyString()] [string] $NamePrefix,
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $parameters = @{} + $PSBoundParameters
    $null = $parameters.Remove('SkipModuleVersionCheck')
    return Get-AvmBicepE2eTestContextInternal @parameters
}
