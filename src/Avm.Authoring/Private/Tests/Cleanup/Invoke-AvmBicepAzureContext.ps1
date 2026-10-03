function Invoke-AvmBicepAzureContext {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [guid] $SubscriptionId,

        [Parameter(Mandatory)]
        [guid] $TenantId,

        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($SubscriptionId -eq [guid]::Empty -or $TenantId -eq [guid]::Empty) {
        throw [AvmConfigurationException]::new('Azure execution requires nonempty subscription and tenant IDs.')
    }
    if (-not $PSCmdlet.ShouldProcess(
            "$SubscriptionId in tenant $TenantId", 'Run in a temporary Azure PowerShell context')) {
        return
    }
    $original = Get-AzContext -ErrorAction Stop
    $account = Get-AvmPropertyValue -InputObject $original -Name 'Account'
    $originalAccount = [string](Get-AvmPropertyValue -InputObject $account -Name 'Id')
    if ([string]::IsNullOrWhiteSpace($originalAccount)) {
        throw [AvmConfigurationException]::new(
            'Azure PowerShell is not authenticated. Use Connect-AzAccount locally, or azure/login with enable-AzPSSession in Actions, before Bicep deployment tests.')
    }
    $originalSubscription = [string](Get-AvmPropertyValue -InputObject (
            Get-AvmPropertyValue -InputObject $original -Name 'Subscription') -Name 'Id')
    $originalTenant = [string](Get-AvmPropertyValue -InputObject (
            Get-AvmPropertyValue -InputObject $original -Name 'Tenant') -Name 'Id')
    $originalEnvironment = [string](Get-AvmPropertyValue -InputObject (
            Get-AvmPropertyValue -InputObject $original -Name 'Environment') -Name 'Name')
    try {
        $selected = Set-AzContext -Subscription $SubscriptionId.ToString('D') `
            -Tenant $TenantId.ToString('D') -Scope Process -ErrorAction Stop
        $selectedSubscription = [string](Get-AvmPropertyValue -InputObject (
                Get-AvmPropertyValue -InputObject $selected -Name 'Subscription') -Name 'Id')
        $selectedTenant = [string](Get-AvmPropertyValue -InputObject (
                Get-AvmPropertyValue -InputObject $selected -Name 'Tenant') -Name 'Id')
        $selectedAccount = [string](Get-AvmPropertyValue -InputObject (
                Get-AvmPropertyValue -InputObject $selected -Name 'Account') -Name 'Id')
        $selectedEnvironment = [string](Get-AvmPropertyValue -InputObject (
                Get-AvmPropertyValue -InputObject $selected -Name 'Environment') -Name 'Name')
        if ($selectedSubscription -ine $SubscriptionId.ToString('D') -or
            $selectedTenant -ine $TenantId.ToString('D') -or
            $selectedAccount -ine $originalAccount -or
            $selectedEnvironment -ine $originalEnvironment) {
            throw [AvmConfigurationException]::new(
                'Azure PowerShell did not select the requested subscription and tenant with the existing account.')
        }
        & $ScriptBlock
    }
    finally {
        try {
            $restored = Set-AzContext -Context $original -Scope Process -ErrorAction Stop
            $restoredSubscription = [string](Get-AvmPropertyValue -InputObject (
                    Get-AvmPropertyValue -InputObject $restored -Name 'Subscription') -Name 'Id')
            $restoredTenant = [string](Get-AvmPropertyValue -InputObject (
                    Get-AvmPropertyValue -InputObject $restored -Name 'Tenant') -Name 'Id')
            $restoredAccount = [string](Get-AvmPropertyValue -InputObject (
                    Get-AvmPropertyValue -InputObject $restored -Name 'Account') -Name 'Id')
            $restoredEnvironment = [string](Get-AvmPropertyValue -InputObject (
                    Get-AvmPropertyValue -InputObject $restored -Name 'Environment') -Name 'Name')
            if ($restoredSubscription -ine $originalSubscription -or
                $restoredTenant -ine $originalTenant -or $restoredAccount -ine $originalAccount -or
                $restoredEnvironment -ine $originalEnvironment) {
                throw [AvmProcessException]::new('Azure context restoration returned a different target or account.')
            }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                    [AvmProcessException]::new('The original Azure PowerShell context could not be restored; no further cleanup should run.'),
                    'AvmBicepContextRestoreFailed',
                    [System.Management.Automation.ErrorCategory]::InvalidResult,
                    $null))
        }
    }
}
