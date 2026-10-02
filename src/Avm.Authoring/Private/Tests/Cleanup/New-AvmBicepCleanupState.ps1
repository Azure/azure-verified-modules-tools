function New-AvmBicepCleanupState {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [guid] $SubscriptionId,

        [Parameter(Mandatory)]
        [guid] $TenantId,

        [Parameter(Mandatory)]
        [string] $Environment,

        [string] $Path,

        [string] $RunId = [guid]::NewGuid().ToString('N')
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $state = @{
        schemaVersion       = 1
        runId               = $RunId
        tenantId            = $TenantId.ToString('D')
        subscriptionId      = $SubscriptionId.ToString('D')
        environment         = $Environment
        status              = 'Pending'
        deployments         = [System.Collections.Generic.List[object]]::new()
        ownedResourceGroups = [System.Collections.Generic.List[object]]::new()
        resources           = [System.Collections.Generic.List[object]]::new()
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-bicep-cleanup-{0}.json' -f $state.runId)
    }
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Create Bicep cleanup state')) {
        return
    }
    Save-AvmBicepCleanupState -State $state -Path $fullPath -Create -Confirm:$false
    return [pscustomobject]@{ State = $state; Path = $fullPath }
}
