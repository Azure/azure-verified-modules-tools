function Get-AvmTelemetryPrefixFromCatalog {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Catalog,

        [string] $ExcludeBicepModulePath
    )

    Set-StrictMode -Version 3.0

    if (-not $Catalog.Contains('modules') -or $Catalog['modules'] -isnot [System.Collections.IDictionary]) {
        throw [System.ArgumentException]::new('The module catalog must contain a modules object.')
    }

    $prefixes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $pending.Enqueue($Catalog['modules'])
    while ($pending.Count -gt 0) {
        $node = $pending.Dequeue()
        if ($node -is [System.Collections.IDictionary]) {
            if ($ExcludeBicepModulePath -and
                $node.Contains('modulePath') -and
                $node['modulePath'] -ceq $ExcludeBicepModulePath -and
                $node['ecosystem'] -ceq 'bicep' -and
                $node['repository'] -ceq 'Azure/bicep-registry-modules') {
                continue
            }
            if ($node.Contains('telemetryIdPrefix') -and -not [string]::IsNullOrWhiteSpace([string]$node['telemetryIdPrefix'])) {
                $null = $prefixes.Add([string]$node['telemetryIdPrefix'])
            }
            if ($node.Contains('alternativeTelemetryIdPrefixes')) {
                foreach ($prefix in @($node['alternativeTelemetryIdPrefixes'])) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$prefix)) {
                        $null = $prefixes.Add([string]$prefix)
                    }
                }
            }
            foreach ($key in @($node.Keys)) {
                $value = $node[$key]
                if ($null -ne $value) {
                    $pending.Enqueue($value)
                }
            }
        }
        elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
            foreach ($item in $node) {
                if ($null -ne $item) {
                    $pending.Enqueue($item)
                }
            }
        }
    }

    return [string[]]@($prefixes)
}
