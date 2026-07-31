function Get-AvmFileSnapshot {
    <#
    .SYNOPSIS
        Capture the on-disk bytes of a set of files so they can be restored later.

    .DESCRIPTION
        Supports the read-only contract of drift mode (-CheckDrift) for engines
        whose underlying tool has no dry-run and can only report drift by
        rewriting the file. The engine snapshots before it runs the tool,
        compares afterwards to detect drift, then restores the snapshot so the
        caller's working copy is left byte-identical.

        Absent paths are recorded with a $null value so Restore-AvmFileSnapshot
        can delete a file the tool created.

    .PARAMETER Path
        Absolute paths to capture. Paths that do not exist are recorded as
        absent rather than skipped.

    .OUTPUTS
        hashtable keyed by path; values are byte[] for existing files and $null
        for absent ones.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $snapshot = @{}

    foreach ($item in $Path) {
        if (-not $item) { continue }
        if ($snapshot.ContainsKey($item)) { continue }

        if (Test-Path -LiteralPath $item -PathType Leaf) {
            $snapshot[$item] = [System.IO.File]::ReadAllBytes($item)
        }
        else {
            $snapshot[$item] = $null
        }
    }

    return $snapshot
}

function Restore-AvmFileSnapshot {
    <#
    .SYNOPSIS
        Restore files captured by Get-AvmFileSnapshot to their original bytes.

    .DESCRIPTION
        Rewrites every snapshotted file whose content changed, deletes files
        that were absent when the snapshot was taken, and deletes any extra
        path supplied via -CurrentPath that the snapshot does not know about
        (i.e. created by the tool). Files whose bytes are already identical are
        left untouched so timestamps stay stable.

        Restoration is best-effort per file: a failure to restore one file does
        not abort the rest, because this runs from a finally block where the
        engine may already be unwinding a tool error.

    .PARAMETER Snapshot
        Hashtable produced by Get-AvmFileSnapshot.

    .PARAMETER CurrentPath
        Optional list of paths that exist now. Any entry absent from the
        snapshot is treated as tool-created and removed.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Snapshot,

        [AllowEmptyCollection()]
        [string[]] $CurrentPath = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    foreach ($item in $Snapshot.Keys) {
        try {
            $original = $Snapshot[$item]
            $exists = Test-Path -LiteralPath $item -PathType Leaf

            if ($null -eq $original) {
                if ($exists) { Remove-Item -LiteralPath $item -Force }
                continue
            }

            if ($exists) {
                $current = [System.IO.File]::ReadAllBytes($item)
                if ([System.Linq.Enumerable]::SequenceEqual([byte[]]$current, [byte[]]$original)) {
                    continue
                }
            }
            else {
                $parent = Split-Path -Parent $item
                if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                    $null = New-Item -ItemType Directory -Path $parent -Force
                }
            }

            [System.IO.File]::WriteAllBytes($item, $original)
        }
        catch {
            Write-Verbose ("Avm: could not restore '{0}': {1}" -f $item, $_.Exception.Message)
        }
    }

    foreach ($item in $CurrentPath) {
        if (-not $item -or $Snapshot.ContainsKey($item)) { continue }
        try {
            if (Test-Path -LiteralPath $item -PathType Leaf) {
                Remove-Item -LiteralPath $item -Force
            }
        }
        catch {
            Write-Verbose ("Avm: could not remove '{0}': {1}" -f $item, $_.Exception.Message)
        }
    }
}
