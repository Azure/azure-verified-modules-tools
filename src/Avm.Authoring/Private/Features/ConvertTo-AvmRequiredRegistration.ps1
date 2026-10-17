function ConvertTo-AvmRequiredRegistration {
    <#
    .SYNOPSIS
        Validate one list of required Azure features or resource providers.

    .DESCRIPTION
        Every entry must be a unique (case-insensitive) ASCII Namespace/FeatureName
        string, or provider namespace, with no whitespace or extra segments. ModulePath only labels errors
        for the repository-root manifest format.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Entries,

        [string] $ModulePath,

        [ValidateSet('Feature', 'Provider')]
        [string] $Kind = 'Feature'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $where = if ($ModulePath) { " entry [$ModulePath]" } else { '' }
    $filename = if ($Kind -eq 'Feature') { '.required-features.json' } else { '.required-resource-providers.json' }
    $format = if ($Kind -eq 'Feature') { 'Namespace/FeatureName' } else { 'provider namespace' }
    if ($Entries.Count -gt 32) {
        throw [AvmConfigurationException]::new(
            "$filename$where must contain no more than 32 $($Kind.ToLowerInvariant())s.")
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $requirements = [System.Collections.Generic.List[pscustomobject]]::new()
    $pattern = '\A(?<namespace>[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+)'
    if ($Kind -eq 'Feature') { $pattern += '/(?<name>[A-Za-z][A-Za-z0-9]*(?:[._-][A-Za-z0-9]+)*)' }
    $pattern += '\z'
    foreach ($entry in $Entries) {
        if ($entry -isnot [string]) {
            throw [AvmConfigurationException]::new(
                "$filename$where entries must all be strings in $format form.")
        }
        $match = [regex]::Match($entry, $pattern)
        if (-not $match.Success -or
            $match.Groups['namespace'].Value.Length -gt 128 -or
            $match.Groups['name'].Value.Length -gt 128) {
            throw [AvmConfigurationException]::new(
                "$filename$where entries must use ASCII $format without whitespace, extra path segments, or command arguments (128 characters per part maximum).")
        }
        if (-not $seen.Add($entry)) {
            throw [AvmConfigurationException]::new(
                "Duplicate $($Kind.ToLowerInvariant()) '$entry' in $filename$where (case-insensitive).")
        }
        $requirements.Add([pscustomobject]@{
                Namespace = $match.Groups['namespace'].Value
                Name      = $match.Groups['name'].Value
                FullName  = $entry
            })
    }

    return $requirements.ToArray()
}
