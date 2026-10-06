function Remove-AvmHclComment {
    <#
    .SYNOPSIS
        Blank out comments and heredoc bodies in HCL source.

    .DESCRIPTION
        Callers scan HCL with regular expressions to find declarations. A
        commented-out declaration must not match, and neither must text that
        merely looks like HCL inside a heredoc.

        Both are common in AVM examples: authors frequently leave alternative
        data sources commented out, and heredocs carry embedded policy or
        script text.

        Comment and heredoc bodies are replaced with spaces rather than
        removed, and newlines are preserved, so every offset and line number
        in the returned text still matches the original.

        Quoted strings are deliberately left intact. Callers match
        declarations such as 'data "type" "name"' whose identifiers are
        themselves quoted, and a single-line HCL string cannot contain the
        newline those patterns anchor to.

        Handles '#' and '//' line comments, '/* */' block comments, and
        heredocs ('<<EOT' and '<<-EOT').

    .PARAMETER Content
        The HCL source text.

    .OUTPUTS
        System.String, the same length as the input.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrEmpty($Content)) {
        return $Content
    }

    $result = [System.Text.StringBuilder]::new($Content)
    $length = $Content.Length
    $index = 0

    while ($index -lt $length) {
        $current = $Content[$index]
        $next = if (($index + 1) -lt $length) { $Content[$index + 1] } else { [char]0 }
        $end = -1

        if ($current -eq '#' -or ($current -eq '/' -and $next -eq '/')) {
            $end = $Content.IndexOf("`n", $index)
            if ($end -lt 0) { $end = $length }
        }
        elseif ($current -eq '/' -and $next -eq '*') {
            $close = $Content.IndexOf('*/', $index + 2)
            $end = if ($close -lt 0) { $length } else { $close + 2 }
        }
        elseif ($current -eq '<' -and $next -eq '<') {
            $header = [regex]::Match(
                $Content.Substring($index),
                '^<<-?(?<delimiter>[A-Za-z_][A-Za-z0-9_]*)',
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
            if ($header.Success) {
                # The body runs to a line containing only the delimiter, so
                # anything inside it is inert.
                $terminator = [regex]::Match(
                    $Content.Substring($index),
                    ('(?m)^[ \t]*{0}[ \t]*$' -f [regex]::Escape($header.Groups['delimiter'].Value)),
                    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
                $end = if ($terminator.Success) {
                    $index + $terminator.Index + $terminator.Length
                }
                else {
                    $length
                }
            }
        }

        if ($end -lt 0) {
            $index++
            continue
        }

        for ($position = $index; $position -lt $end; $position++) {
            if ($Content[$position] -ne "`n" -and $Content[$position] -ne "`r") {
                $result[$position] = ' '
            }
        }
        $index = $end
    }

    return $result.ToString()
}
