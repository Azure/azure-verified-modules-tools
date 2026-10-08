function Test-AvmBicepRetryErrorNode {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Node,

        [ValidateSet('Regional', 'Transient')]
        [string] $RetryKind = 'Regional',

        [string] $SubscriptionId,
        [string] $ResourceLocation,
        [int] $Depth = 0,
        [string] $ResourceTarget,
        [string] $WorkspaceTarget,
        [string] $AksPreflightMessage,
        [string[]] $Targets = @(),
        [hashtable] $Evidence
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $context = @{
        RetryKind = $RetryKind; SubscriptionId = $SubscriptionId; ResourceLocation = $ResourceLocation
        Depth = $Depth; ResourceTarget = $ResourceTarget; WorkspaceTarget = $WorkspaceTarget
        AksPreflightMessage = $AksPreflightMessage; Targets = $Targets; Evidence = $Evidence
    }
    if ($null -eq $Evidence) {
        $context.Evidence = @{ Narrow = $false; Unknown = $false }
        $qualified = Test-AvmBicepRetryErrorNode -Node $Node @context
        return $qualified -and (-not $context.Evidence.Narrow -or -not $context.Evidence.Unknown)
    }
    if ($Depth -gt 20 -or $null -eq $Node) { return $false }
    $context.Depth = $Depth + 1
    if ($Node -is [System.Collections.IEnumerable] -and
        $Node -isnot [string] -and $Node -isnot [System.Collections.IDictionary]) {
        $children = @($Node)
        if ($children.Count -eq 0) { return $false }
        foreach ($child in $children) {
            if (-not (Test-AvmBicepRetryErrorNode -Node $child @context)) { return $false }
        }
        return $true
    }
    if ($Node -is [string] -or $Node -is [System.ValueType]) { return $false }
    $properties = @{}
    $names = if ($Node -is [System.Collections.IDictionary]) { $Node.psbase.Keys } else { $Node.PSObject.Properties.Name }
    foreach ($name in $names) {
        if ($properties.ContainsKey($name)) { return $false }
        if ($Node -is [System.Collections.IDictionary]) {
            $properties[$name] = $Node[$name]
        }
        else {
            $properties[$name] = $Node.PSObject.Properties[$name].Value
        }
    }
    if ($null -ne $properties['status'] -and
        ($properties['status'] -isnot [string] -or $properties['status'] -cne 'Failed')) { return $false }
    if ($properties.ContainsKey('error')) {
        if ($properties.ContainsKey('code') -or $properties.ContainsKey('details') -or
            $properties.ContainsKey('innererror')) { return $false }
        if (@($properties.psbase.Keys | Where-Object { $_ -notin @('error', 'status') }).Count -gt 0 -or
            ($properties.ContainsKey('status') -and $properties['status'] -cne 'Failed')) {
            $Evidence.Unknown = $true
        }
        return Test-AvmBicepRetryErrorNode -Node $properties['error'] @context
    }
    $code = $properties['code']
    if ($code -isnot [string] -or [string]::IsNullOrWhiteSpace($code) -or $properties['additionalInfo']) {
        return $false
    }
    foreach ($optional in @('target', 'details')) {
        if ($properties.ContainsKey($optional) -and $null -eq $properties[$optional]) { $properties.Remove($optional) }
    }
    if (@($properties.psbase.Keys | Where-Object { $_ -notin @('code', 'message', 'target', 'details', 'innererror') }).Count -gt 0 -or
        ($properties.ContainsKey('message') -and $properties['message'] -isnot [string]) -or
        ($properties.ContainsKey('target') -and ($properties['target'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($properties['target'])))) {
        $Evidence.Unknown = $true
    }
    if ($properties['target'] -is [string]) { $context.Targets = @($Targets) + $properties['target'] }
    $children = @()
    if ($null -ne $properties['details']) {
        if ($properties['details'] -isnot [System.Collections.IList]) { return $false }
        $children += $properties['details']
    }
    if ($null -ne $properties['innererror']) { $children += , $properties['innererror'] }
    $context.ResourceTarget = ''
    $context.WorkspaceTarget = ''
    $context.AksPreflightMessage = ''
    $subscription = [guid]::Empty
    if ($code -eq 'ResourceDeploymentFailure' -and $properties['target'] -is [string] -and
        [guid]::TryParseExact($SubscriptionId, 'D', [ref]$subscription) -and $subscription -ne [guid]::Empty) {
        $types = if ($RetryKind -eq 'Transient') {
            '(?:Microsoft\.Network/(?:applicationGateways|privateEndpoints)|Microsoft\.DBforPostgreSQL/flexibleServers)'
        }
        else { 'Microsoft\.ContainerInstance/containerGroups' }
        $targetPattern = '\A/subscriptions/' + [regex]::Escape($subscription.ToString('D')) +
        "/resourceGroups/[^/?#\s]+/providers/$types/[^/?#\s]+\z"
        if ($properties['target'] -match $targetPattern) { $context.ResourceTarget = $properties['target'] }
    }
    if ($RetryKind -eq 'Regional' -and $context.ResourceTarget -and
        -not [string]::IsNullOrWhiteSpace($ResourceLocation) -and
        $properties['details'] -is [System.Collections.IList] -and $properties['details'].Count -eq 1 -and
        $null -eq $properties['innererror'] -and $children[0] -is [System.Collections.IDictionary] -and
        $children[0].psbase.Count -eq 1 -and $children[0]['message'] -is [string]) {
        $pattern = "\AThe requested resource is not available in the location '$([regex]::Escape($ResourceLocation))' at this moment\. " +
        "Please retry with a different resource request or in another location\. Resource requested: '(?<cpu>[0-9]+(?:\.[0-9]+)?)' CPU '(?<memory>[0-9]+(?:\.[0-9]+)?)' GB memory 'Linux' OS\z"
        $capacity = [regex]::Match($children[0]['message'], $pattern)
        if ($capacity.Success) {
            $Evidence.Narrow = $true
            $cpu = [double]::Parse($capacity.Groups['cpu'].Value, [System.Globalization.CultureInfo]::InvariantCulture)
            $memory = [double]::Parse($capacity.Groups['memory'].Value, [System.Globalization.CultureInfo]::InvariantCulture)
            return $cpu -gt 0 -and $cpu -le 4 -and $memory -gt 0 -and $memory -le 16
        }
    }
    $guidPattern = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
    if ($code -eq 'ResourceDeploymentFailure' -and $properties['target'] -is [string] -and
        $properties['target'] -match "\A/subscriptions/$guidPattern/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft\.MachineLearningServices/workspaces/[A-Za-z0-9_-]+\z") {
        $context.WorkspaceTarget = $properties['target']
    }
    if ($code -ceq 'InvalidTemplateDeployment' -and $properties['message'] -is [string] -and
        -not $properties.ContainsKey('target') -and -not $properties.ContainsKey('innererror')) {
        $context.AksPreflightMessage = $properties['message']
    }
    foreach ($child in $children) {
        if (-not (Test-AvmBicepRetryErrorNode -Node $child @context)) { return $false }
    }
    if ($code -in @('InvalidTemplateDeployment', 'DeploymentFailed', 'MultipleErrorsOccurred', 'ResourceDeploymentFailure')) {
        return $children.Count -gt 0
    }
    $message = $properties['message']
    if ($message -isnot [string]) { return $false }
    if ($RetryKind -eq 'Transient') {
        $Evidence.Narrow = $true
        return $code -ceq 'InternalServerError' -and $children.Count -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($message) -and -not [string]::IsNullOrWhiteSpace($ResourceTarget) -and
        ($null -eq $properties['target'] -or $properties['target'] -ieq $ResourceTarget)
    }
    if ($code -cin @('ResourcesForSkuUnavailable', 'BadRequest', 'ManagedEnvironmentCapacityHeavyUsageError')) {
        $Evidence.Narrow = $true
        if (-not $properties.ContainsKey('details') -and -not $properties.ContainsKey('innererror') -and
            (Test-AvmBicepRegionalServiceError -Code $code -Message $message -ResourceLocation $ResourceLocation `
                -SubscriptionId $SubscriptionId -Targets $context.Targets)) {
            return $true
        }
    }
    switch ($code) {
        'LocationNotAvailableForResourceType' {
            $Evidence.Narrow = $true
            if ($code -cne 'LocationNotAvailableForResourceType' -or [string]::IsNullOrWhiteSpace($ResourceLocation) -or
                $properties.ContainsKey('target') -or $properties.ContainsKey('details') -or
                $properties.ContainsKey('innererror')) { return $false }
            $pattern = "\AThe provided location '(?<location>[A-Za-z0-9]+(?: [A-Za-z0-9]+)*)' is not available for resource type " +
            "'Microsoft\.[A-Za-z0-9]+/[A-Za-z0-9]+(?:/[A-Za-z0-9]+)*'\. List of available regions for the resource type is " +
            "'(?<regions>[a-z0-9]+(?:,[a-z0-9]+)*)'\.\z"
            $match = [regex]::Match($message, $pattern)
            if (-not $match.Success) { return $false }
            $reportedLocation = ($match.Groups['location'].Value -replace '\s', '').ToLowerInvariant()
            $availableRegions = $match.Groups['regions'].Value.Split(',')
            return $reportedLocation -eq ($ResourceLocation -replace '\s', '').ToLowerInvariant() -and
            $reportedLocation -ne 'global' -and 'global' -notin $availableRegions -and
            $reportedLocation -notin $availableRegions -and
            @($availableRegions | Select-Object -Unique).Count -eq $availableRegions.Count
        }
        'AvailabilityZoneNotSupported' {
            $Evidence.Narrow = $true
            if ($code -cne 'AvailabilityZoneNotSupported' -or [string]::IsNullOrWhiteSpace($AksPreflightMessage) -or
                $properties.ContainsKey('target') -or $properties.ContainsKey('details') -or
                $properties.ContainsKey('innererror')) { return $false }
            return Test-AvmBicepAksZoneCapacity -Message $message -ParentMessage $AksPreflightMessage -ResourceLocation $ResourceLocation
        }
        'BadRequest' {
            $Evidence.Narrow = $true
            if ([string]::IsNullOrWhiteSpace($WorkspaceTarget) -or
                $properties.ContainsKey('details') -or $properties.ContainsKey('innererror') -or
                ($properties.ContainsKey('target') -and $properties['target'] -ine $WorkspaceTarget)) { return $false }
            return Test-AvmBicepCosmosCapacity -Message $message -ResourceLocation $ResourceLocation
        }
        'RequestDisallowedByAzure' {
            return $message -match 'https://aka\.ms/locationineligible(?:[?#\s).,;:''"]|$)'
        }
        { $_ -in @('AllocationFailed', 'ZonalAllocationFailed', 'InsufficientCapacity') } {
            return $message -match '\b(capacity|allocation)\b' -and $message -match '\b(region|location|zone)\b'
        }
        'SkuNotAvailable' {
            return $message -match '\b(capacity|not available)\b' -and $message -match '\b(region|location)\b'
        }
        default { return $false }
    }
}
