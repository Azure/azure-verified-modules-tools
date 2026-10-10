function Test-AvmBicepRetryErrorNode {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] [object] $Node,
        [ValidateSet('Regional', 'Transient')] [string] $RetryKind = 'Regional',
        [string] $SubscriptionId,
        [string] $ResourceLocation,
        [System.Collections.IDictionary] $Policy,
        [int] $Depth = 0,
        [hashtable] $Parent = @{},
        [string[]] $Targets = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($null -eq $Policy) { $Policy = Get-AvmBicepRetryPolicy }
    if ($Depth -gt 20 -or $null -eq $Node) { return $false }
    $context = @{
        RetryKind = $RetryKind; SubscriptionId = $SubscriptionId; ResourceLocation = $ResourceLocation
        Policy = $Policy; Depth = $Depth + 1; Parent = $Parent; Targets = $Targets
    }
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
    if ($Node -is [System.Exception]) {
        $record = [System.Management.Automation.ErrorRecord]::new($Node, 'BicepRetryEvidence', 'NotSpecified', $null)
        if ($null -ne $Node.InnerException -or $Node.Data.Count -gt 0 -or
            (Get-AvmBicepDeploymentErrorKind -ErrorRecord $record) -ne 'Other') { return $false }
        $names = @($names | Where-Object { $_ -notin @('Data', 'InnerException', 'TargetSite', 'HelpLink', 'Source', 'HResult', 'StackTrace') })
    }
    foreach ($name in $names) {
        if ($properties.ContainsKey($name)) { return $false }
        if ($Node -is [System.Collections.IDictionary]) { $properties[$name] = $Node[$name] }
        else { $properties[$name] = $Node.PSObject.Properties[$name].Value }
    }
    if ($properties.ContainsKey('error')) {
        if (@($properties.psbase.Keys | Where-Object { $_ -notin @('error', 'status') }).Count -gt 0 -or
            ($properties.ContainsKey('status') -and $properties['status'] -cne 'Failed')) { return $false }
        return Test-AvmBicepRetryErrorNode -Node $properties['error'] @context
    }
    foreach ($optional in @('target', 'details')) {
        if ($properties.ContainsKey($optional) -and $null -eq $properties[$optional]) { $properties.Remove($optional) }
    }
    if (@($properties.psbase.Keys | Where-Object { $_ -notin @('code', 'message', 'target', 'details', 'innererror') }).Count -gt 0 -or
        ($properties.ContainsKey('code') -and ($properties['code'] -isnot [string] -or -not $properties['code'])) -or
        ($properties.ContainsKey('message') -and $properties['message'] -isnot [string]) -or
        ($properties.ContainsKey('target') -and ($properties['target'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($properties['target']))) -or
        ($properties.ContainsKey('details') -and $properties['details'] -isnot [System.Collections.IList]) -or
        ($properties.ContainsKey('innererror') -and $null -eq $properties['innererror'])) { return $false }
    $code = [string]$properties['code']
    if ($code -match '(?i)authorization|authentication|unauthorized|forbidden|cancel|permission' -or
        [string]$properties['message'] -match '(?i)\b(authorization|authentication|unauthorized|forbidden|permission)\b') {
        return $false
    }
    if ($properties.ContainsKey('target')) { $context.Targets = @($Targets) + $properties['target'] }
    if ($code -cin $Policy['wrappers']) {
        $children = @()
        if ($properties.ContainsKey('details')) { $children += $properties['details'] }
        if ($properties.ContainsKey('innererror')) { $children += , $properties['innererror'] }
        if ($children.Count -eq 0) { return $false }
        $context.Parent = $properties
        foreach ($child in $children) {
            if (-not (Test-AvmBicepRetryErrorNode -Node $child @context)) { return $false }
        }
        return $true
    }
    $mode = if ($RetryKind -eq 'Regional') { 'Fresh' } else { 'InPlace' }
    foreach ($rule in $Policy['rules']) {
        if ($rule['mode'] -ceq $mode -and
            (Test-AvmBicepRetryRule -Rule $rule -Node $properties -Parent $Parent -Targets $context.Targets `
                -SubscriptionId $SubscriptionId -ResourceLocation $ResourceLocation)) { return $true }
    }
    return $false
}
