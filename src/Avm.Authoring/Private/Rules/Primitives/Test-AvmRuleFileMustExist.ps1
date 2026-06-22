function Test-AvmRuleFileMustExist {
    <#
    .SYNOPSIS
        Primitive: assert that a named file exists in the target root.

    .DESCRIPTION
        Used by AVM convention rules that require a specific file (e.g.
        'terraform.tf' or '_header.md').

        Slice B cross-cutting decision #3: this primitive deliberately has
        NO fix path. An auto-created empty file would just trade one
        violation for another (an empty file would itself fail downstream
        formatting or content checks). The author is the only sensible
        source of the file's content.

        Parameters honoured on the rule:
          - Path (required, string) : path relative to TargetRoot.

    .PARAMETER Rule
        AvmRule pscustomobject (typically produced by New-AvmRule).

    .PARAMETER TargetRoot
        Absolute path to the directory the rule applies to.

    .PARAMETER Fix
        Accepted but ignored. Present so the engine's per-primitive
        dispatcher has a uniform signature; documented as report-only here.

    .OUTPUTS
        [pscustomobject] with Status, Issues, FilesChanged.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] [string] $TargetRoot,
        [switch] $Fix
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $null = $Fix

    $path = [string]$Rule.Parameters.Path
    $full = Join-Path $TargetRoot $path

    if (Test-Path -LiteralPath $full -PathType Leaf) {
        return [pscustomobject][ordered]@{
            Status       = 'pass'
            Issues       = @()
            FilesChanged = 0
        }
    }

    $issues = @(
        [pscustomobject][ordered]@{
            File     = $path
            Line     = 0
            Column   = 0
            Severity = $Rule.Severity
            Code     = $Rule.Id
            Message  = "Required file '$path' does not exist."
        }
    )

    return [pscustomobject][ordered]@{
        Status       = 'fail'
        Issues       = $issues
        FilesChanged = 0
    }
}
