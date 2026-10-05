function Assert-AvmBicepAzureIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $AzPath,

        [Parameter(Mandatory)]
        [guid] $SubscriptionId,

        [Parameter(Mandatory)]
        [guid] $TenantId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $native = Get-AzContext -ErrorAction Stop
    $nativeSubscription = [string](Get-AvmPropertyValue -InputObject (
            Get-AvmPropertyValue -InputObject $native -Name 'Subscription') -Name 'Id')
    $nativeTenant = [string](Get-AvmPropertyValue -InputObject (
            Get-AvmPropertyValue -InputObject $native -Name 'Tenant') -Name 'Id')
    $nativeAccount = [string](Get-AvmPropertyValue -InputObject (
            Get-AvmPropertyValue -InputObject $native -Name 'Account') -Name 'Id')
    $nativeEnvironment = [string](Get-AvmPropertyValue -InputObject (
            Get-AvmPropertyValue -InputObject $native -Name 'Environment') -Name 'Name')
    if ($SubscriptionId -eq [guid]::Empty -or $TenantId -eq [guid]::Empty -or
        $nativeSubscription -ine $SubscriptionId.ToString('D') -or
        $nativeTenant -ine $TenantId.ToString('D') -or
        [string]::IsNullOrWhiteSpace($nativeAccount) -or
        [string]::IsNullOrWhiteSpace($nativeEnvironment)) {
        throw [AvmConfigurationException]::new(
            'Azure PowerShell does not confirm the requested Bicep test subscription, tenant and authenticated account.')
    }
    $result = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
        'account', 'show', '--subscription', $SubscriptionId.ToString('D'), '--output', 'json'
    ) -IgnoreExitCode
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result.StdOut) -or
        -not (Test-Json -Json $result.StdOut -ErrorAction SilentlyContinue)) {
        throw [AvmConfigurationException]::new(
            'Cannot verify the Azure CLI account for Bicep cleanup. Authenticate Azure CLI and Azure PowerShell before deploying.')
    }
    $selected = $result.StdOut | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $cliAccount = [string](Get-AvmPropertyValue -InputObject (
            Get-AvmPropertyValue -InputObject $selected -Name 'user') -Name 'name')
    if ($selected -isnot [System.Collections.IDictionary] -or
        $selected['id'] -ine $nativeSubscription -or $selected['tenantId'] -ine $nativeTenant -or
        $selected['environmentName'] -ine $nativeEnvironment -or
        $selected['state'] -cne 'Enabled' -or $cliAccount -ine $nativeAccount) {
        throw [AvmConfigurationException]::new(
            'Azure CLI and Azure PowerShell must use the same enabled subscription, tenant, cloud and account for Bicep deployment and cleanup. In Actions, enable the Azure PowerShell session in azure/login.')
    }
}
