function Get-AvmBicepTestGroupResource {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($RunId -cnotmatch '^[0-9a-f]{32}$' -or
        -not $ResourceGroupName.EndsWith("-$RunId", [System.StringComparison]::Ordinal)) {
        throw [AvmConfigurationException]::new(
            'Bicep e2e resource-group resources require the exact per-case group and run ID.')
    }
    $prefix = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/"
    if (-not $ResourceId.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e resource '$ResourceId' is outside its run-owned group.")
    }
    $segments = $ResourceId.Substring($prefix.Length).Split('/')
    if ($segments.Length -lt 3 -or $segments.Length % 2 -ne 1 -or
        $segments[0] -cnotmatch '^[A-Za-z][A-Za-z0-9.-]*$') {
        throw [AvmConfigurationException]::new(
            "Bicep e2e resource '$ResourceId' has an uninspectable group resource ID.")
    }
    $types = [System.Collections.Generic.List[string]]::new()
    $names = [System.Collections.Generic.List[string]]::new()
    for ($index = 1; $index -lt $segments.Length; $index += 2) {
        if ($segments[$index] -cnotmatch '^[A-Za-z][A-Za-z0-9]*$' -or
            $segments[$index] -ieq 'providers' -or
            $segments[$index + 1] -cnotmatch '^[^/?#%\\\[\]]+$' -or
            $segments[$index + 1] -in @('.', '..')) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e resource '$ResourceId' has an uninspectable group resource ID.")
        }
        $types.Add($segments[$index])
        $names.Add($segments[$index + 1])
    }
    $type = '{0}/{1}' -f $segments[0], ($types -join '/')
    if ($type -ieq 'Microsoft.Resources/resourceGroups' -or
        $type -ieq 'Microsoft.Resources/deploymentScripts' -or
        $type.StartsWith('Microsoft.Authorization/', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e resource '$ResourceId' has a prohibited group resource type.")
    }
    return [pscustomobject]@{
        Id        = $ResourceId
        Type      = $type
        Name      = $names -join '/'
        GroupName = $ResourceGroupName
        Kind      = if ($type -ieq 'Microsoft.Resources/deployments') { 'Deployment' } else { 'Resource' }
    }
}
