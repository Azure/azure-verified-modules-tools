function Test-AvmBicepRegionalErrorNode {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Node,

        [int] $Depth = 0
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Depth -gt 20 -or $null -eq $Node) { return $false }
    if ($Node -is [System.Collections.IEnumerable] -and
        $Node -isnot [string] -and $Node -isnot [System.Collections.IDictionary]) {
        $children = @($Node)
        if ($children.Count -eq 0) { return $false }
        foreach ($child in $children) {
            if (-not (Test-AvmBicepRegionalErrorNode -Node $child -Depth ($Depth + 1))) { return $false }
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
    if ($properties.ContainsKey('error')) {
        if ($properties.ContainsKey('code') -or $properties.ContainsKey('details') -or
            $properties.ContainsKey('innererror')) { return $false }
        return Test-AvmBicepRegionalErrorNode -Node $properties['error'] -Depth ($Depth + 1)
    }
    $code = $properties['code']
    if ($code -isnot [string] -or [string]::IsNullOrWhiteSpace($code) -or $properties['additionalInfo']) {
        return $false
    }
    $children = @()
    if ($null -ne $properties['details']) {
        if ($properties['details'] -isnot [System.Collections.IList]) { return $false }
        $children += $properties['details']
    }
    if ($null -ne $properties['innererror']) { $children += , $properties['innererror'] }
    foreach ($child in $children) {
        if (-not (Test-AvmBicepRegionalErrorNode -Node $child -Depth ($Depth + 1))) { return $false }
    }
    if ($code -in @('InvalidTemplateDeployment', 'DeploymentFailed', 'MultipleErrorsOccurred')) {
        return $children.Count -gt 0
    }
    $message = $properties['message']
    if ($message -isnot [string]) { return $false }
    switch ($code) {
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
