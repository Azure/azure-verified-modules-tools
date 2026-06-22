function Test-AvmRuleGitignoreMustContain {
    <#
    .SYNOPSIS
        Primitive: assert that the .gitignore file in the target root
        contains every required glob from the rule's RequiredGlobs set.

    .DESCRIPTION
        Reads <TargetRoot>/.gitignore. Each line of the file is trimmed and
        compared by exact (ordinal, case-sensitive) match against each
        glob in Parameters.RequiredGlobs. Lines that begin with '#' (after
        trim) are treated as comments and never match. Blank lines never
        match.

        Pass: every required glob has at least one matching non-comment
        line. Fail: at least one required glob is absent.

        Fix path (with -Fix): if the file is missing or any glob is absent,
        write a new file (or append to the existing one) that ensures every
        required glob is present at least once. Existing lines are
        preserved verbatim and the file gets a trailing newline. With -Fix,
        the result Status is 'fixed' on any change; no Issues are emitted.
        Without -Fix, every missing glob produces one Issue.

        The presence check is exact-string-match on a trimmed line; we do
        not attempt to expand globs or detect semantic overlap (e.g.
        '*.tfstate' covers '*.tfstate.backup'). That keeps the rule
        deterministic and the per-glob diagnostic actionable.

        Parameters honoured on the rule:
          - RequiredGlobs (required, string[]) : ordered list of globs.

    .PARAMETER Rule
        AvmRule pscustomobject (typically produced by New-AvmRule).

    .PARAMETER TargetRoot
        Absolute path to the directory the rule applies to.

    .PARAMETER Fix
        When set, creates or appends to <TargetRoot>/.gitignore so that
        every required glob is present.

    .OUTPUTS
        [pscustomobject] with Status, Issues, FilesChanged.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] [string] $TargetRoot,
        [switch] $Fix
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $requiredGlobs = @($Rule.Parameters.RequiredGlobs | ForEach-Object { [string]$_ })
    $gitignorePath = Join-Path $TargetRoot '.gitignore'

    $existingLines = @()
    if (Test-Path -LiteralPath $gitignorePath -PathType Leaf) {
        $raw = [System.IO.File]::ReadAllText($gitignorePath, [System.Text.UTF8Encoding]::new($false))
        # Normalise CRLF -> LF before split so a CRLF-edited file still parses cleanly,
        # then preserve original lines verbatim (no trim) so a fix-write keeps the
        # author's original whitespace and comments untouched.
        $existingLines = ($raw -replace "`r`n", "`n").Split("`n")
        # The trailing newline produces an empty final element from Split -- drop it
        # so we don't emit a spurious blank line on fix-append.
        if ($existingLines.Length -gt 0 -and $existingLines[-1] -eq '') {
            $existingLines = $existingLines[0..($existingLines.Length - 2)]
        }
    }

    # Build the trimmed, comment-stripped set used for membership tests.
    $presentGlobs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($line in $existingLines) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        [void]$presentGlobs.Add($trimmed)
    }

    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($glob in $requiredGlobs) {
        if (-not $presentGlobs.Contains($glob)) {
            $missing.Add($glob)
        }
    }

    if ($missing.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Status       = 'pass'
            Issues       = @()
            FilesChanged = 0
        }
    }

    if ($Fix) {
        $appendBlock = New-Object 'System.Collections.Generic.List[string]'
        $appendBlock.AddRange([string[]]$existingLines)
        foreach ($glob in $missing) {
            $appendBlock.Add($glob)
        }
        $newContent = ($appendBlock -join "`n") + "`n"

        if ($PSCmdlet.ShouldProcess($gitignorePath, 'Append required globs')) {
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($gitignorePath, $newContent, $utf8NoBom)
        }

        return [pscustomobject][ordered]@{
            Status       = 'fixed'
            Issues       = @()
            FilesChanged = 1
        }
    }

    $issues = New-Object 'System.Collections.Generic.List[object]'
    foreach ($glob in $missing) {
        $issues.Add([pscustomobject][ordered]@{
                File     = '.gitignore'
                Line     = 0
                Column   = 0
                Severity = $Rule.Severity
                Code     = $Rule.Id
                Message  = "'.gitignore' is missing required glob '$glob' (run with -Fix to append)."
            })
    }

    return [pscustomobject][ordered]@{
        Status       = 'fail'
        Issues       = $issues.ToArray()
        FilesChanged = 0
    }
}
