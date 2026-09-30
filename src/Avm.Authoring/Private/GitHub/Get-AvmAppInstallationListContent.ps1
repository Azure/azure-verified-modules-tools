function Get-AvmAppInstallationListContent {
    <#
    .SYNOPSIS
        Add a repository to the top-level repositories list of an app installation YAML file.
    .DESCRIPTION
        Returns the content with the repository inserted in case-insensitive
        order, preserving every other line and the file's line endings. Listed
        is true when the repository is already present, in which case the
        content is returned unchanged.
    .PARAMETER Content
        App installation YAML content.
    .PARAMETER Repository
        Repository name to include.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content,

        [Parameter(Mandatory)]
        [string] $Repository
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new([string[]]($Content -split '\r?\n'))
    $keyIndexes = @(for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -cmatch '^repositories:\s*$') { $index }
        })
    if ($keyIndexes.Count -ne 1) {
        throw [System.IO.InvalidDataException]::new(
            'The app installation file must contain exactly one top-level repositories list.')
    }

    $start = $keyIndexes[0] + 1
    $end = $start
    $indent = '  '
    $names = [System.Collections.Generic.List[string]]::new()
    while ($end -lt $lines.Count) {
        $item = [regex]::Match($lines[$end], '^(?<indent>[ ]+)-[ ]+(?<name>[^\s#]+)\s*$')
        if (-not $item.Success) {
            break
        }
        $indent = $item.Groups['indent'].Value
        $names.Add($item.Groups['name'].Value)
        $end++
    }

    foreach ($name in $names) {
        if ([string]::Equals($name, $Repository, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Content = $Content; Changed = $false; Listed = $true }
        }
    }
    $insertAt = $end
    for ($index = 0; $index -lt $names.Count; $index++) {
        if ([string]::Compare($names[$index], $Repository, [System.StringComparison]::OrdinalIgnoreCase) -gt 0) {
            $insertAt = $start + $index
            break
        }
    }
    $lines.Insert($insertAt, "$indent- $Repository")
    return [pscustomobject]@{ Content = ($lines -join $newline); Changed = $true; Listed = $false }
}
