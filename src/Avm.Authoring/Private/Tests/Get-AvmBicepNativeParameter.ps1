function Get-AvmBicepNativeParameter {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $ParameterPath,

        [System.Collections.IDictionary] $Parameters = @{}
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $result = @{}
    if (-not [string]::IsNullOrWhiteSpace($ParameterPath)) {
        $document = Get-Content -LiteralPath $ParameterPath -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($document -isnot [System.Collections.IDictionary] -or
            $document['parameters'] -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new('The ARM parameter file must contain a parameters object.')
        }
        foreach ($name in $document['parameters'].psbase.Keys) {
            $entry = $document['parameters'][$name]
            if ($entry -isnot [System.Collections.IDictionary] -or
                $entry.Contains('value') -eq $entry.Contains('reference')) {
                throw [AvmConfigurationException]::new("ARM parameter '$name' must specify either value or reference.")
            }
            if ($entry.Contains('reference')) {
                $result[$name] = @{ reference = $entry['reference'] }
            }
            else {
                $result[$name] = $entry['value']
                if ($result[$name] -is [hashtable] -and $result[$name].ContainsKey('reference')) {
                    $value = [ordered]@{}
                    foreach ($key in $result[$name].psbase.Keys) { $value[$key] = $result[$name][$key] }
                    $result[$name] = $value
                }
            }
        }
    }
    foreach ($name in $Parameters.psbase.Keys) {
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) {
            throw [AvmConfigurationException]::new('Bicep test parameter names must be nonempty strings.')
        }
        $result[$name] = $Parameters[$name]
        if ($result[$name] -is [hashtable] -and $result[$name].ContainsKey('reference')) {
            $value = [ordered]@{}
            foreach ($key in $result[$name].psbase.Keys) { $value[$key] = $result[$name][$key] }
            $result[$name] = $value
        }
    }
    return $result
}
