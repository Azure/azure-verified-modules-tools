function Test-AvmRuleDirectoryMustExist {
    <#
    .SYNOPSIS
        Primitive: assert that a named directory exists in the target root.

    .DESCRIPTION
        Used by AVM convention rules that require a specific directory
        (e.g. 'examples' and 'tests').

        Slice B cross-cutting decision #2: this primitive deliberately has
        NO fix path. The upstream grept policy materialised a '.gitkeep' in
        the missing directory; that turned a real missing-content problem
        into a hidden one (the directory existed but was empty, so the
        downstream checks that actually cared about its contents could not
        report a useful diagnostic). The author is the only sensible source
        of the directory's purpose.

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

    if (Test-Path -LiteralPath $full -PathType Container) {
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
            Message  = "Required directory '$path' does not exist."
        }
    )

    return [pscustomobject][ordered]@{
        Status       = 'fail'
        Issues       = $issues
        FilesChanged = 0
    }
}
