function ConvertTo-AvmReleaseNormalizedText {
    <#
    .SYNOPSIS
        Normalise Markdown text before the release engine compares or stores it.

    .DESCRIPTION
        Converts line endings to LF, removes trailing whitespace from each line, and drops leading and trailing blank lines. Inner blank lines and indentation are kept, so Markdown structure survives. Null or blank input returns an empty string.

    .PARAMETER Text
        The text to normalise.

    .EXAMPLE
        ConvertTo-AvmReleaseNormalizedText -Text "`r`nHello  `r`n`r`n"

        Returns 'Hello'.

    .OUTPUTS
        String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $lines = @(($Text -replace "`r`n?", "`n") -split "`n" | ForEach-Object { $_.TrimEnd() })
    $first = 0
    while ($first -lt $lines.Count -and $lines[$first].Length -eq 0) {
        $first++
    }
    $last = $lines.Count - 1
    while ($last -gt $first -and $lines[$last].Length -eq 0) {
        $last--
    }
    return ($lines[$first..$last] -join "`n")
}
