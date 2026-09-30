function Get-AvmLegacyReadmeNote {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content
    )

    Set-StrictMode -Version 3.0
    $normalized = $Content.ReplaceLineEndings("`n")
    if (-not $normalized.Contains('## Notes')) {
        return $null
    }

    $fenceCharacter = $null
    $fenceLength = 0
    $bodyStart = -1
    $bodyEnd = $normalized.Length
    foreach ($line in [regex]::Matches($normalized, '[^\n]*(?:\n|$)')) {
        if ($line.Length -eq 0) {
            continue
        }
        $text = $line.Value.TrimEnd("`n")
        if ($fenceCharacter) {
            $closing = '^[ ]{0,3}' + [regex]::Escape($fenceCharacter) +
            '{' + $fenceLength + ',}[ \t]*$'
            if ($text -cmatch $closing) {
                $fenceCharacter = $null
            }
            continue
        }
        if ($text -cmatch '^[ ]{0,3}(?<run>`{3,}|~{3,})') {
            $fenceCharacter = $Matches['run'][0]
            $fenceLength = $Matches['run'].Length
            continue
        }
        if ($text -cmatch '^##[ \t]+Notes[ \t]*$') {
            if ($bodyStart -ge 0) {
                $bodyEnd = $line.Index
                break
            }
            $bodyStart = $line.Index + $line.Length
            continue
        }
        if ($bodyStart -ge 0 -and $text -cmatch '^##[ \t]+') {
            $bodyEnd = $line.Index
            break
        }
    }
    if ($bodyStart -lt 0) {
        return $null
    }

    return [pscustomobject]@{
        Body = $normalized.Substring($bodyStart, $bodyEnd - $bodyStart)
    }
}
