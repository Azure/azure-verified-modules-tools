function ConvertFrom-AvmDotEnv {
    <#
    .SYNOPSIS
        Parse a '.env' file into a hashtable of environment overrides.

    .DESCRIPTION
        The e2e '.env' bridge. A per-example 'pre.ps1' hook runs in its own
        pwsh subprocess, so any environment variables it exports do NOT reach
        the CLI's own process. The porch convention is instead for the hook to
        write KEY=VALUE lines to a '.env' file next to the example; the runner
        then sources that file into every terraform subprocess. This helper is
        the parser for that file.

        It mirrors a pragmatic subset of the shell 'set -a; . ./.env; set +a'
        behaviour porch relies on:

          - Blank lines, and lines whose first non-whitespace character is '#',
            are ignored.
          - An optional leading 'export ' is stripped.
          - The key is everything before the first '='; surrounding whitespace
            is trimmed. A line with no '=', or with an empty key, is ignored.
          - The value is everything after the first '='. A single matching pair
            of surrounding single or double quotes is removed; otherwise the
            value is trimmed of surrounding whitespace.

        A missing or empty file yields an empty hashtable, so callers can pass
        the result straight to Invoke-AvmProcess -EnvVars unconditionally.

    .PARAMETER Path
        Path to the '.env' file. A path that does not resolve to a file returns
        an empty hashtable rather than throwing.

    .OUTPUTS
        System.Collections.Hashtable mapping variable name to string value.

    .EXAMPLE
        PS> ConvertFrom-AvmDotEnv -Path (Join-Path $exampleDir '.env')
        Name                           Value
        ----                           -----
        ARM_SUBSCRIPTION_ID            00000000-0000-0000-0000-000000000000
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $result = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $result
    }

    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($trimmed.StartsWith('export ')) {
            $trimmed = $trimmed.Substring('export '.Length).TrimStart()
        }

        $eq = $trimmed.IndexOf('=')
        if ($eq -lt 1) {
            continue
        }

        $key = $trimmed.Substring(0, $eq).Trim()
        if ($key.Length -eq 0) {
            continue
        }

        $value = $trimmed.Substring($eq + 1)
        $isDoubleQuoted = $value.StartsWith('"') -and $value.EndsWith('"')
        $isSingleQuoted = $value.StartsWith("'") -and $value.EndsWith("'")
        if ($value.Length -ge 2 -and ($isDoubleQuoted -or $isSingleQuoted)) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        else {
            $value = $value.Trim()
        }

        $result[$key] = $value
    }

    return $result
}
