function Get-AvmManagedLineSpecFileName {
    <#
    .SYNOPSIS
        The sentinel file name that carries a line-managed-file spec inside a
        managed-files overlay directory.

    .DESCRIPTION
        The spec lives beside the overlay content (in 'root' and each group
        overlay) so it stacks per repository group exactly like the files
        themselves. It is tooling metadata, not synced content, so
        Add-AvmManagedFilesFromDir filters it out of the managed-files map the
        same way it filters '.gitkeep'.
    #>
    [OutputType([string])]
    param()
    return '.avm-managed-lines.json'
}

function Merge-AvmFileLine {
    <#
    .SYNOPSIS
        Line-level merge: ensure every required line is present and every removed
        line is absent, preserving all other existing lines and their order.

    .DESCRIPTION
        Pure function (no I/O). Matching is exact on the trimmed line text and
        case-sensitive. Required lines that are already present are left in place;
        genuinely missing ones are appended at the end in declaration order.
        Every occurrence of a removed line is deleted. Blank lines are never
        removed. The operation is idempotent: re-running over its own output
        reports no change.

        A line supplied in both Required and Removed is a contradiction and
        throws, so a bad spec fails loudly rather than resolving silently.

    .OUTPUTS
        pscustomobject with Lines (string[]), Added (string[]),
        Removed (string[]), and Changed (bool).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $ExistingLine = @(),
        [string[]] $Required = @(),
        [string[]] $Removed = @()
    )

    Set-StrictMode -Version 3.0

    $existing = @($ExistingLine)
    $required = @($Required)
    $removed = @($Removed)

    $removedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $removed) {
        if ($null -eq $item) { continue }
        $trimmed = ([string]$item).Trim()
        if ($trimmed.Length -eq 0) { continue }
        [void]$removedSet.Add($trimmed)
    }
    foreach ($item in $required) {
        if ($null -eq $item) { continue }
        $trimmed = ([string]$item).Trim()
        if ($removedSet.Contains($trimmed)) {
            throw [System.ArgumentException]::new(
                "Line '$trimmed' appears in both 'required' and 'removed'; a managed-line spec entry cannot require and remove the same line.")
        }
    }

    $kept = New-Object System.Collections.Generic.List[string]
    $removedLines = New-Object System.Collections.Generic.List[string]
    $presentTrimmed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($line in $existing) {
        $value = if ($null -eq $line) { '' } else { [string]$line }
        $trimmed = $value.Trim()
        if ($trimmed.Length -gt 0 -and $removedSet.Contains($trimmed)) {
            $removedLines.Add($value)
            continue
        }
        $kept.Add($value)
        if ($trimmed.Length -gt 0) { [void]$presentTrimmed.Add($trimmed) }
    }

    $addedLines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $required) {
        if ($null -eq $item) { continue }
        $value = [string]$item
        $trimmed = $value.Trim()
        if ($trimmed.Length -eq 0) { continue }
        if ($presentTrimmed.Contains($trimmed)) { continue }
        $kept.Add($value)
        $addedLines.Add($value)
        [void]$presentTrimmed.Add($trimmed)
    }

    return [pscustomobject][ordered]@{
        Lines   = $kept.ToArray()
        Added   = $addedLines.ToArray()
        Removed = $removedLines.ToArray()
        Changed = (($addedLines.Count -gt 0) -or ($removedLines.Count -gt 0))
    }
}

function Get-AvmManagedLineSpec {
    <#
    .SYNOPSIS
        Collect and stack the line-managed-file spec across a repository's
        managed-file groups.

    .DESCRIPTION
        Reads one '<base>/<group>/.avm-managed-lines.json' per file group, in
        the same order Build-AvmManagedFilesMap applies the groups. Each spec is
        a flat JSON map of forward-slash relative path ->
        { required: [...], removed: [...] }.

        Entries stack per line with last-writer-wins: a later group that
        requires a line cancels an earlier group that removed it, and vice
        versa, mirroring how later group files win over earlier ones. Within a
        single spec file a line in both 'required' and 'removed' is a
        contradiction and throws.

    .OUTPUTS
        An ordered hashtable keyed by relative path; each value is a
        pscustomobject with Required (string[]) and Removed (string[]).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $BaseDir,

        [string[]] $FileGroups = @()
    )

    Set-StrictMode -Version 3.0

    $specFileName = Get-AvmManagedLineSpecFileName

    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($fileGroup in $FileGroups) {
        if ([string]::IsNullOrWhiteSpace($fileGroup)) { continue }
        $dirs.Add((Join-Path $BaseDir $fileGroup))
    }

    $spec = [ordered]@{}

    foreach ($dir in $dirs) {
        $specFile = Join-Path $dir $specFileName
        if (-not (Test-Path -LiteralPath $specFile -PathType Leaf)) { continue }

        $raw = Get-Content -LiteralPath $specFile -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        try {
            $parsed = $raw | ConvertFrom-Json
        }
        catch {
            throw [System.InvalidOperationException]::new(
                "Managed-line spec '$specFile' is not valid JSON: $($_.Exception.Message)")
        }
        if ($null -eq $parsed) { continue }

        foreach ($property in $parsed.PSObject.Properties) {
            $targetPath = ($property.Name -replace '\\', '/').Trim()
            if ([string]::IsNullOrWhiteSpace($targetPath)) { continue }

            $entry = $property.Value
            if ($null -eq $entry) { continue }

            $required = @()
            $removed = @()
            if ($entry.PSObject.Properties.Name -contains 'required' -and $entry.required) {
                $required = @($entry.required)
            }
            if ($entry.PSObject.Properties.Name -contains 'removed' -and $entry.removed) {
                $removed = @($entry.removed)
            }

            $fileRequired = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($r in $required) {
                if ($null -eq $r) { continue }
                $t = ([string]$r).Trim()
                if ($t.Length -gt 0) { [void]$fileRequired.Add($t) }
            }
            foreach ($r in $removed) {
                if ($null -eq $r) { continue }
                $t = ([string]$r).Trim()
                if ($t.Length -gt 0 -and $fileRequired.Contains($t)) {
                    throw [System.InvalidOperationException]::new(
                        "Managed-line spec '$specFile' lists line '$t' for '$targetPath' in both 'required' and 'removed'.")
                }
            }

            if (-not $spec.Contains($targetPath)) {
                $spec[$targetPath] = [pscustomobject]@{
                    Required = (New-Object System.Collections.Generic.List[string])
                    Removed  = (New-Object System.Collections.Generic.List[string])
                }
            }
            $bucket = $spec[$targetPath]

            foreach ($r in $required) {
                if ($null -eq $r) { continue }
                $value = [string]$r
                $trimmed = $value.Trim()
                if ($trimmed.Length -eq 0) { continue }
                for ($i = $bucket.Removed.Count - 1; $i -ge 0; $i--) {
                    if ($bucket.Removed[$i].Trim() -ceq $trimmed) { $bucket.Removed.RemoveAt($i) }
                }
                if (-not ($bucket.Required | Where-Object { $_.Trim() -ceq $trimmed })) {
                    $bucket.Required.Add($value)
                }
            }
            foreach ($r in $removed) {
                if ($null -eq $r) { continue }
                $value = [string]$r
                $trimmed = $value.Trim()
                if ($trimmed.Length -eq 0) { continue }
                for ($i = $bucket.Required.Count - 1; $i -ge 0; $i--) {
                    if ($bucket.Required[$i].Trim() -ceq $trimmed) { $bucket.Required.RemoveAt($i) }
                }
                if (-not ($bucket.Removed | Where-Object { $_.Trim() -ceq $trimmed })) {
                    $bucket.Removed.Add($value)
                }
            }
        }
    }

    $result = [ordered]@{}
    foreach ($key in $spec.Keys) {
        $result[$key] = [pscustomobject]@{
            Required = $spec[$key].Required.ToArray()
            Removed  = $spec[$key].Removed.ToArray()
        }
    }
    return $result
}

function Get-AvmManagedLinePlan {
    <#
    .SYNOPSIS
        Compute the per-file line-merge plan for a resolved line-managed-file
        spec against a working tree, without writing anything.

    .DESCRIPTION
        For each spec path it reads the current file (if any), detects the
        dominant line ending, and computes the merged content via
        Merge-AvmFileLine. A missing file is treated as empty so required lines
        create it (new files use LF); an existing file keeps its own line ending.
        All content is read and written as UTF-8 without a BOM.

    .OUTPUTS
        An array of pscustomobject, one per spec path, with Path, Full, Existed,
        Changed, AddedLines, RemovedLines, and NewText.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary] $Spec
    )

    Set-StrictMode -Version 3.0

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $plans = New-Object System.Collections.Generic.List[object]

    foreach ($targetPath in $Spec.Keys) {
        $entry = $Spec[$targetPath]
        $full = Join-Path $Root ($targetPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))

        $existed = Test-Path -LiteralPath $full -PathType Leaf
        $newline = "`n"
        $existingLines = @()
        if ($existed) {
            $text = $utf8NoBom.GetString([System.IO.File]::ReadAllBytes($full))
            if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
            if ($text.Contains("`r`n")) { $newline = "`r`n" }
            $existingLines = @([regex]::Split($text, "`r`n|`n|`r"))
            if ($existingLines.Count -gt 0 -and $existingLines[-1] -eq '') {
                if ($existingLines.Count -eq 1) {
                    $existingLines = @()
                }
                else {
                    $existingLines = @($existingLines[0..($existingLines.Count - 2)])
                }
            }
        }

        $merge = Merge-AvmFileLine -ExistingLine $existingLines -Required $entry.Required -Removed $entry.Removed

        $newText = ''
        if ($merge.Lines.Count -gt 0) { $newText = ($merge.Lines -join $newline) + $newline }

        $plans.Add([pscustomobject][ordered]@{
                Path         = $targetPath
                Full         = $full
                Existed      = $existed
                Changed      = $merge.Changed
                AddedLines   = $merge.Added
                RemovedLines = $merge.Removed
                NewText      = $newText
            })
    }

    return $plans.ToArray()
}
