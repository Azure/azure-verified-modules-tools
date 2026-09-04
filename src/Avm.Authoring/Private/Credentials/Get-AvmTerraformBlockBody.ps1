function Get-AvmTerraformBlockBody {
    <#
    .SYNOPSIS
        Return the text inside an HCL block, given its opening brace.

    .DESCRIPTION
        Brace-matches from the opening brace to its partner so callers can
        inspect one block in isolation.

        Comments are expected to have been stripped already (see
        Remove-AvmHclComment), so only string literals need skipping to avoid
        counting a brace inside a quoted value.

    .PARAMETER Content
        The HCL source text.

    .PARAMETER OpenBraceIndex
        Index of the block's opening brace within Content.

    .OUTPUTS
        System.String. Empty when the block is unterminated.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Content,

        [Parameter(Mandatory)]
        [int] $OpenBraceIndex
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $depth = 0
    $inString = $false
    $escaped = $false

    for ($index = $OpenBraceIndex; $index -lt $Content.Length; $index++) {
        $current = $Content[$index]

        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($current -eq '\') { $escaped = $true }
            elseif ($current -eq '"') { $inString = $false }
            continue
        }

        if ($current -eq '"') {
            $inString = $true
            continue
        }
        if ($current -eq '{') {
            $depth++
            continue
        }
        if ($current -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $Content.Substring($OpenBraceIndex + 1, $index - $OpenBraceIndex - 1)
            }
        }
    }

    return ''
}
