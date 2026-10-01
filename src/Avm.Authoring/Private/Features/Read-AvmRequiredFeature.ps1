function Read-AvmRequiredFeature {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $files = @(Get-ChildItem -LiteralPath $Root -File -Force |
            Where-Object { $_.Name -ieq '.required-features.json' })
    if ($files.Count -eq 0) {
        return
    }
    if ($files.Count -ne 1 -or $files[0].Name -cne '.required-features.json') {
        throw [AvmConfigurationException]::new(
            "The required-features manifest must be named exactly '.required-features.json' at the module root.")
    }
    if ($files[0].Length -gt 65536) {
        throw [AvmConfigurationException]::new(
            '.required-features.json exceeds the 64 KiB limit.')
    }

    $contents = Get-Content -LiteralPath $files[0].FullName -Raw -Encoding utf8
    try {
        $entries = ConvertFrom-Json -InputObject $contents -NoEnumerate -ErrorAction Stop
    }
    catch {
        throw [AvmConfigurationException]::new(
            '.required-features.json must contain a valid JSON array of feature names.',
            $_.Exception)
    }

    if ($entries -isnot [array]) {
        throw [AvmConfigurationException]::new(
            '.required-features.json must contain a top-level JSON array of feature names.')
    }
    if ($entries.Count -gt 32) {
        throw [AvmConfigurationException]::new(
            '.required-features.json must contain no more than 32 features.')
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $features = [System.Collections.Generic.List[pscustomobject]]::new()
    $pattern = '\A(?<namespace>[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+)/(?<name>[A-Za-z][A-Za-z0-9]*(?:[._-][A-Za-z0-9]+)*)\z'
    foreach ($entry in $entries) {
        if ($entry -isnot [string]) {
            throw [AvmConfigurationException]::new(
                '.required-features.json entries must all be strings in Namespace/FeatureName form.')
        }
        $match = [regex]::Match($entry, $pattern)
        if (-not $match.Success -or
            $match.Groups['namespace'].Value.Length -gt 128 -or
            $match.Groups['name'].Value.Length -gt 128) {
            throw [AvmConfigurationException]::new(
                '.required-features.json entries must use ASCII Namespace/FeatureName without whitespace, extra path segments, or command arguments (128 characters per part maximum).')
        }
        if (-not $seen.Add($entry)) {
            throw [AvmConfigurationException]::new(
                "Duplicate feature '$entry' in .required-features.json (case-insensitive).")
        }
        $features.Add([pscustomobject]@{
                Namespace = $match.Groups['namespace'].Value
                Name      = $match.Groups['name'].Value
                FullName  = $entry
            })
    }

    return $features.ToArray()
}
