function Get-AvmBicepScopedResource {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [ValidateSet('sub', 'mg', 'tenant')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $RunId,

        [string] $ManagementGroupId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $prefix = switch ($Scope) {
        'sub' { "/subscriptions/$SubscriptionId/providers/" }
        'mg' {
            if ([string]::IsNullOrWhiteSpace($ManagementGroupId)) {
                throw [AvmConfigurationException]::new('Management-group e2e requires -ManagementGroupId.')
            }
            "/providers/Microsoft.Management/managementGroups/$ManagementGroupId/providers/"
        }
        'tenant' { '/providers/' }
    }
    $kind = ''
    $type = ''
    $name = ''
    $group = ''
    if ($Scope -eq 'sub') {
        $groupMatch = [regex]::Match(
            $ResourceId, ('^/subscriptions/{0}/resourceGroups/(?<name>[^/?#]+)$' -f
                [regex]::Escape($SubscriptionId)),
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($groupMatch.Success) {
            $kind = 'Group'
            $type = 'Microsoft.Resources/resourceGroups'
            $name = $groupMatch.Groups['name'].Value
            $group = $name
        }
    }
    if (-not $kind) {
        $resourceMatch = [regex]::Match(
            $ResourceId,
            ('^{0}(?<type>Microsoft\.Authorization/(?:policyDefinitions|policySetDefinitions|roleDefinitions))/(?<name>[^/?#]+)$' -f [regex]::Escape($prefix)),
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $deploymentMatch = [regex]::Match(
            $ResourceId,
            ('^{0}Microsoft\.Resources/deployments/(?<name>[^/?#]+)$' -f [regex]::Escape($prefix)),
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($resourceMatch.Success) {
            $kind = 'Resource'
            $type = $resourceMatch.Groups['type'].Value
            $name = $resourceMatch.Groups['name'].Value
        }
        elseif ($deploymentMatch.Success) {
            $kind = 'Deployment'
            $type = 'Microsoft.Resources/deployments'
            $name = $deploymentMatch.Groups['name'].Value
        }
        else {
            throw [AvmConfigurationException]::new(
                "Bicep e2e resource '$ResourceId' is outside the explicit $Scope target or has an unsupported type.")
        }
    }
    if ($kind -ne 'Deployment' -and
        -not $name.Contains($RunId.Substring(0, 10), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e resource '$ResourceId' lacks the generated per-case run suffix; use #_avmE2eSuffix_# or a run-specific namePrefix.")
    }
    return [pscustomobject]@{
        Id        = $ResourceId
        Type      = $type
        Name      = $name
        GroupName = $group
        Kind      = $kind
    }
}
