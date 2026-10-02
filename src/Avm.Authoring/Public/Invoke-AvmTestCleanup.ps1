function Invoke-AvmTestCleanup {
    <#
    .SYNOPSIS
        Resume Bicep test cleanup from its saved JSON state.
    .DESCRIPTION
        Retries unfinished deployment-owned cleanup using an existing Azure
        PowerShell and Azure CLI sign-in. The supplied subscription and tenant
        must match the saved state. Unknown deployment outcomes are checked
        before removal; active or unverified deployments retain their resources.
        The file remains available after success or failure. A downloaded Actions
        artifact can be used in the same way as a locally saved file.
        This command does not log in, install modules, or execute test hooks.
    .PARAMETER StatePath
        Existing cleanup JSON file. Relative paths use the current PowerShell location.
    .PARAMETER SubscriptionId
        Explicit test subscription GUID recorded in the state file.
    .PARAMETER TenantId
        Explicit test tenant GUID recorded in the state file.
    .PARAMETER SearchRetryLimit
        Maximum attempts to establish deployment outcomes and discover missing
        deployment records. Defaults to 40.
    .PARAMETER SearchRetryInterval
        Seconds between deployment status or discovery attempts. Defaults to 60.
    .PARAMETER RemovalRetryLimit
        Maximum cleanup passes over unfinished resources. Defaults to three.
    .PARAMETER RemovalRetryInterval
        Seconds between cleanup passes. Defaults to 15.
    .PARAMETER SkipModuleVersionCheck
        Skip the installed-module version check.
    .EXAMPLE
        avm test cleanup --state-path cleanup.json --subscription-id $testSubscriptionId --tenant-id $testTenantId
    .EXAMPLE
        Invoke-AvmTestCleanup -StatePath cleanup.json -SubscriptionId $testSubscriptionId -TenantId $testTenantId -WhatIf
    .OUTPUTS
        A result with Status, Cleaned, CleanupPending, Issues and StatePath.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $StatePath,

        [Parameter(Mandatory)]
        [guid] $SubscriptionId,

        [Parameter(Mandatory)]
        [guid] $TenantId,

        [ValidateRange(1, 1000)]
        [int] $SearchRetryLimit = 40,

        [ValidateRange(0, 3600)]
        [int] $SearchRetryInterval = 60,

        [ValidateRange(1, 100)]
        [int] $RemovalRetryLimit = 3,

        [ValidateRange(0, 3600)]
        [int] $RemovalRetryInterval = 15,

        [switch] $SkipModuleVersionCheck
    )

    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
    }
    process {
        Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
        $inputOptions = @{
            StatePath            = $StatePath
            SubscriptionId       = $SubscriptionId
            TenantId             = $TenantId
            SearchRetryLimit     = $SearchRetryLimit
            SearchRetryInterval  = $SearchRetryInterval
            RemovalRetryLimit    = $RemovalRetryLimit
            RemovalRetryInterval = $RemovalRetryInterval
        }
        $approved = $PSCmdlet.ShouldProcess(
            "$StatePath for subscription $SubscriptionId, tenant $TenantId", 'Resume Bicep test cleanup')
        $result = Invoke-AvmBicepCleanup @inputOptions -WhatIf:(-not $approved) -Confirm:$false
        return [pscustomobject]@{
            Engine         = 'bicep'
            Tool           = 'Azure PowerShell'
            Status         = $result.Status
            Cleaned        = $result.Cleaned
            CleanupPending = $result.Pending
            Issues         = $result.Issues
            StatePath      = $result.StatePath
        }
    }
}
