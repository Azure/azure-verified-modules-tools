function ConvertTo-AvmRequiredFeature {
    <#
    .SYNOPSIS
        Validate one list of required Azure feature names from .required-features.json.

    .DESCRIPTION
        Every entry must be a unique (case-insensitive) ASCII Namespace/FeatureName
        string with no whitespace or extra segments. ModulePath only labels errors
        for the repository-root manifest format.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Entries,

        [string] $ModulePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $where = if ($ModulePath) { " entry [$ModulePath]" } else { '' }
    if ($Entries.Count -gt 32) {
        throw [AvmConfigurationException]::new(
            ".required-features.json$where must contain no more than 32 features.")
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $features = [System.Collections.Generic.List[pscustomobject]]::new()
    $pattern = '\A(?<namespace>[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+)/(?<name>[A-Za-z][A-Za-z0-9]*(?:[._-][A-Za-z0-9]+)*)\z'
    foreach ($entry in $Entries) {
        if ($entry -isnot [string]) {
            throw [AvmConfigurationException]::new(
                ".required-features.json$where entries must all be strings in Namespace/FeatureName form.")
        }
        $match = [regex]::Match($entry, $pattern)
        if (-not $match.Success -or
            $match.Groups['namespace'].Value.Length -gt 128 -or
            $match.Groups['name'].Value.Length -gt 128) {
            throw [AvmConfigurationException]::new(
                ".required-features.json$where entries must use ASCII Namespace/FeatureName without whitespace, extra path segments, or command arguments (128 characters per part maximum).")
        }
        if (-not $seen.Add($entry)) {
            throw [AvmConfigurationException]::new(
                "Duplicate feature '$entry' in .required-features.json$where (case-insensitive).")
        }
        $features.Add([pscustomobject]@{
                Namespace = $match.Groups['namespace'].Value
                Name      = $match.Groups['name'].Value
                FullName  = $entry
            })
    }

    return $features.ToArray()
}
