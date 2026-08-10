function Test-AvmRuleFileMustNotExist {
    <#
    .SYNOPSIS
        Primitive: assert that a named file does NOT exist in the target root.

    .DESCRIPTION
        Used by AVM convention rules that need to forbid the presence of a
        specific file (e.g. 'output.tf' should be renamed to 'outputs.tf').

        Parameters honoured on the rule:
          - Path        (required, string)  : path relative to TargetRoot.
          - FixRenameTo (optional, string)  : when -Fix is set and the file
                                              exists, rename it to this name
                                              inside the same directory. If
                                              the destination exists, append
                                              non-whitespace source content
                                              before removing the source.

        Without -Fix, a present file produces a single Issue with Severity
        from the rule and Code = rule.Id, and Status='fail'. With -Fix and
        FixRenameTo declared, the rename is performed and Status='fixed'
        (no Issue emitted). An existing destination is preserved: meaningful
        source content is appended with a line boundary, while a whitespace-only
        source is removed without changing the destination. With -Fix but no
        FixRenameTo declared, the rule still reports a violation.

    .PARAMETER Rule
        AvmRule pscustomobject (typically produced by New-AvmRule).

    .PARAMETER TargetRoot
        Absolute path to the directory the rule applies to (module root, an
        examples/* subdir, etc.).

    .PARAMETER Fix
        When set, applies the rename when FixRenameTo is declared.

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

    $path = [string]$Rule.Parameters.Path
    $full = Join-Path $TargetRoot $path

    $issues = New-Object 'System.Collections.Generic.List[object]'
    $filesChanged = 0

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            Status       = 'pass'
            Issues       = @()
            FilesChanged = 0
        }
    }

    $renameTarget = $null
    if ($Rule.Parameters.ContainsKey('FixRenameTo')) {
        $renameTarget = [string]$Rule.Parameters.FixRenameTo
    }

    if ($Fix -and $renameTarget) {
        $destination = Join-Path $TargetRoot $renameTarget
        $pathComparison = if ([System.OperatingSystem]::IsWindows()) {
            [System.StringComparison]::OrdinalIgnoreCase
        }
        else {
            [System.StringComparison]::Ordinal
        }
        $sourcePath = [System.IO.Path]::GetFullPath($full)
        $destinationPath = [System.IO.Path]::GetFullPath($destination)
        if ([string]::Equals($sourcePath, $destinationPath, $pathComparison)) {
            $issues.Add([pscustomobject][ordered]@{
                    File     = $path
                    Line     = 0
                    Column   = 0
                    Severity = $Rule.Severity
                    Code     = $Rule.Id
                    Message  = "Cannot rename '$path' to '$renameTarget': source and destination resolve to the same file."
                })
            return [pscustomobject][ordered]@{
                Status       = 'fail'
                Issues       = $issues.ToArray()
                FilesChanged = 0
            }
        }

        if (Test-Path -LiteralPath $destination) {
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                $issues.Add([pscustomobject][ordered]@{
                        File     = $path
                        Line     = 0
                        Column   = 0
                        Severity = $Rule.Severity
                        Code     = $Rule.Id
                        Message  = "Cannot rename '$path' to '$renameTarget': destination already exists."
                    })
                return [pscustomobject][ordered]@{
                    Status       = 'fail'
                    Issues       = $issues.ToArray()
                    FilesChanged = 0
                }
            }

            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            $sourceContent = [System.IO.File]::ReadAllText($full, $utf8NoBom)
            $hasSourceContent = -not [string]::IsNullOrWhiteSpace($sourceContent)
            $action = if ($hasSourceContent) {
                "Append content to '$renameTarget' and remove source file"
            }
            else {
                "Remove whitespace-only source because '$renameTarget' already exists"
            }

            if ($PSCmdlet.ShouldProcess($full, $action)) {
                if ($hasSourceContent) {
                    $destinationContent = [System.IO.File]::ReadAllText($destination, $utf8NoBom)
                    $destinationEndsWithLineBreak = $destinationContent.EndsWith("`n") -or $destinationContent.EndsWith("`r")
                    $sourceStartsWithLineBreak = $sourceContent.StartsWith("`n") -or $sourceContent.StartsWith("`r")
                    $separator = if ($destinationContent.Length -gt 0 -and -not $destinationEndsWithLineBreak -and -not $sourceStartsWithLineBreak) {
                        "`n"
                    }
                    else {
                        ''
                    }
                    [System.IO.File]::WriteAllText(
                        $destination,
                        $destinationContent + $separator + $sourceContent,
                        $utf8NoBom)
                }

                Remove-Item -LiteralPath $full
                $filesChanged = if ($hasSourceContent) { 2 } else { 1 }
            }

            return [pscustomobject][ordered]@{
                Status       = 'fixed'
                Issues       = @()
                FilesChanged = $filesChanged
            }
        }

        if ($PSCmdlet.ShouldProcess($full, "Rename to '$renameTarget'")) {
            Move-Item -LiteralPath $full -Destination $destination
            $filesChanged = 1
        }

        return [pscustomobject][ordered]@{
            Status       = 'fixed'
            Issues       = @()
            FilesChanged = $filesChanged
        }
    }

    $msg = if ($renameTarget) {
        "File '$path' must not exist; rename to '$renameTarget' (run with -Fix to apply)."
    }
    else {
        "File '$path' must not exist."
    }

    $issues.Add([pscustomobject][ordered]@{
            File     = $path
            Line     = 0
            Column   = 0
            Severity = $Rule.Severity
            Code     = $Rule.Id
            Message  = $msg
        })

    return [pscustomobject][ordered]@{
        Status       = 'fail'
        Issues       = $issues.ToArray()
        FilesChanged = 0
    }
}
