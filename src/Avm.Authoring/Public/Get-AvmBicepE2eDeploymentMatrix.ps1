function Get-AvmBicepE2eDeploymentMatrix {
    <#
    .SYNOPSIS
        Build native Bicep E2E deployment selections without Azure access.

    .DESCRIPTION
        Validates mapped module identity and tenant inputs, selects only General
        subscriptions through Select-AvmTestSubscription, compiles each runnable
        test, and records its reviewed isolation/concurrency evidence. Ignored
        tests remain in the returned matrix but do not require credentials,
        identity mapping, compilation, or a subscription.

    .PARAMETER Root
        Existing filesystem repository root.
    .PARAMETER ModulePath
        Exact repository-relative Bicep module path.
    .PARAMETER TestFiles
        Test records with path, name, and e2eIgnore properties.
    .PARAMETER PoolJson
        Optional native test subscription pool JSON.
    .PARAMETER FallbackSubscriptionId
        General-only fallback subscription when PoolJson is empty.
    .PARAMETER ModuleClientIds
        Required JSON object mapping canonical module roots to client GUIDs.
    .PARAMETER TenantId
        Required nonempty tenant GUID.
    .PARAMETER RandomSeed
        Deterministic subscription-selection seed.
    .PARAMETER DisplaySubscriptionNames
        Include configured subscription names rather than ordinal display names.
    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery version check for source or offline callers.
    .OUTPUTS
        PSCustomObject records with Path, Name, E2eIgnore, subscription selection,
        identity, isolation, and concurrency properties.
    .EXAMPLE
        PS> Get-AvmBicepE2eDeploymentMatrix -Root $repo -ModulePath $module -TestFiles $tests -FallbackSubscriptionId $subscription -ModuleClientIds $mapping -TenantId $tenant
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The command returns one matrix entry for every E2E test case.')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ModulePath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $TestFiles,
        [AllowEmptyString()] [string] $PoolJson,
        [AllowEmptyString()] [string] $FallbackSubscriptionId,
        [AllowEmptyString()] [string] $ModuleClientIds,
        [AllowEmptyString()] [string] $TenantId,
        [ValidateRange(0, [int]::MaxValue)] [int] $RandomSeed = 0,
        [switch] $DisplaySubscriptionNames,
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $parameters = @{} + $PSBoundParameters
    $null = $parameters.Remove('SkipModuleVersionCheck')
    return Get-AvmBicepE2eDeploymentMatrixInternal @parameters
}
