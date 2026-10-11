function Get-AvmBicepScopedResource {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [ValidateSet('sub', 'mg', 'tenant', 'group')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $RunId,

        [string] $ManagementGroupId,

        [string] $OwnedGroupName
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-AvmBicepRunId -RunId $RunId)) {
        throw [AvmConfigurationException]::new('Bicep e2e run ID must be 32 lowercase hexadecimal characters.')
    }
    if ($Scope -eq 'group' -and [string]::IsNullOrWhiteSpace($OwnedGroupName)) {
        throw [AvmConfigurationException]::new(
            'A group-scoped Bicep deployment requires an explicit run-owned group name.')
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnedGroupName) -and
        ($Scope -notin @('sub', 'group') -or
        $OwnedGroupName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,89}$' -or
        -not $OwnedGroupName.Contains($RunId.Substring(0, 10),
            [System.StringComparison]::OrdinalIgnoreCase))) {
        throw [AvmConfigurationException]::new(
            'A Bicep run-owned group must be in the selected subscription and contain the per-case suffix.')
    }
    $prefix = switch ($Scope) {
        'sub' { "/subscriptions/$SubscriptionId/providers/" }
        'group' { "/subscriptions/$SubscriptionId/resourceGroups/$OwnedGroupName/providers/" }
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
        if ($groupMatch.Success -and
            ([string]::IsNullOrWhiteSpace($OwnedGroupName) -or
            [string]::Equals($groupMatch.Groups['name'].Value, $OwnedGroupName,
                [System.StringComparison]::OrdinalIgnoreCase))) {
            $kind = 'Group'
            $type = 'Microsoft.Resources/resourceGroups'
            $name = $groupMatch.Groups['name'].Value
            $group = $name
        }
    }
    if (-not $kind) {
        if ($Scope -eq 'sub' -and -not [string]::IsNullOrWhiteSpace($OwnedGroupName)) {
            $prefix = "/subscriptions/$SubscriptionId/resourceGroups/$OwnedGroupName/providers/"
        }
        $resourceTypes = if ($Scope -eq 'group' -or
            -not [string]::IsNullOrWhiteSpace($OwnedGroupName)) {
            'Microsoft\.Network/routeTables'
        }
        else {
            'Microsoft\.Authorization/(?:policyDefinitions|policySetDefinitions|roleDefinitions)'
        }
        $resourcePattern = '^{0}(?<type>{1})/(?<name>[^/?#]+)$' -f [regex]::Escape($prefix), $resourceTypes
        $resourceMatch = [regex]::Match(
            $ResourceId, $resourcePattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $deploymentMatch = [regex]::Match(
            $ResourceId,
            ('^{0}Microsoft\.Resources/deployments/(?<name>[^/?#]+)$' -f [regex]::Escape($prefix)),
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($resourceMatch.Success) {
            $kind = 'Resource'
            $type = $resourceMatch.Groups['type'].Value
            $name = $resourceMatch.Groups['name'].Value
            if ($Scope -eq 'group' -or
                -not [string]::IsNullOrWhiteSpace($OwnedGroupName)) {
                $group = $OwnedGroupName
            }
        }
        elseif ($deploymentMatch.Success) {
            $kind = 'Deployment'
            $type = 'Microsoft.Resources/deployments'
            $name = $deploymentMatch.Groups['name'].Value
            if ($Scope -eq 'group' -or
                -not [string]::IsNullOrWhiteSpace($OwnedGroupName)) {
                $group = $OwnedGroupName
            }
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
