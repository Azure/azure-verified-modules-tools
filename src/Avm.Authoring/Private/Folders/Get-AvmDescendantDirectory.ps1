function Get-AvmDescendantDirectory {
    <#
    .SYNOPSIS
        Enumerate the directories below $Root, pruning build-artifact subtrees.

    .DESCRIPTION
        Depth-first walk that never descends into a directory for which
        Test-AvmIgnoredPath returns true, so a populated '.terraform/' costs one
        test rather than a walk of every module it downloaded.

        Returns DirectoryInfo records in an array (empty when nothing matches)
        so callers can rely on '.Count'. Directories that cannot be read are
        skipped rather than thrown on, matching the -ErrorAction SilentlyContinue
        posture the rule primitives use elsewhere.

    .PARAMETER Root
        Absolute path to walk. Not itself returned.

    .OUTPUTS
        [object[]] of System.IO.DirectoryInfo.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $results = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $results.ToArray()
    }

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-AvmIgnoredPath -Root $Root -Path $child.FullName) {
                continue
            }

            $results.Add($child)
            $pending.Push($child.FullName)
        }
    }

    return $results.ToArray()
}
