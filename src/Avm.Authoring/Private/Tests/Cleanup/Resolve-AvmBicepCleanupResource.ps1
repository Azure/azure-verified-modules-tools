function Resolve-AvmBicepCleanupResource {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $container = [regex]::Match($ResourceId,
        '^/subscriptions/(?<subscription>[^/]+)/resourceGroups/(?<group>[^/]+)/providers/(?<provider>[^/]+)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $container.Success) {
        return ConvertTo-AvmBicepCleanupResource -ResourceIds @($ResourceId)
    }
    $null = ConvertTo-AvmBicepCleanupResource -ResourceIds @($ResourceId + '/avmExpansionProbe/value')
    $subscription = $container.Groups['subscription'].Value
    $groupName = $container.Groups['group'].Value
    $tenant = [string](Get-AvmPropertyValue -InputObject (
            Get-AvmPropertyValue -InputObject (Get-AzContext -ErrorAction Stop) -Name 'Tenant') -Name 'Id')
    Invoke-AvmBicepAzureContext -SubscriptionId $subscription -TenantId $tenant -ScriptBlock {
        foreach ($resource in @(Invoke-AvmBicepCleanupLookup -Command Get-AzResource `
                    -Parameters @{ ResourceGroupName = $groupName })) {
            if ($null -eq $resource) { continue }
            $id = Get-AvmPropertyValue -InputObject $resource -Name 'ResourceId'
            if ([string]::IsNullOrEmpty($id)) { $id = Get-AvmPropertyValue -InputObject $resource -Name 'Id' }
            if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id)) {
                throw [AvmProcessException]::new('Provider-container expansion returned a resource without an ID.')
            }
            if ($id.StartsWith($ResourceId + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                ConvertTo-AvmBicepCleanupResource -ResourceIds @($id)
            }
        }
    } -Confirm:$false
}
