function Get-AvmCatalogCsvRowSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Rows)

    $snapshot = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Rows) {
        if ([string]::IsNullOrWhiteSpace([string]$row['ModuleName'])) {
            throw [System.IO.InvalidDataException]::new('A source CSV row has no ModuleName; its identity cannot be protected.')
        }
        $snapshot.Add([ordered]@{
                moduleName = [string]$row['ModuleName']
                repoURL = [string]$row['RepoURL']
            })
    }
    return ,$snapshot.ToArray()
}

function Get-AvmCatalogCsvRowKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Row,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Output,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [switch] $RequireResolved
    )

    Assert-AvmCatalogManifestKeys -Value $Row -Keys @('moduleName', 'repoURL')
    if ($Row.moduleName -isnot [string] -or [string]::IsNullOrWhiteSpace($Row.moduleName) -or $Row.repoURL -isnot [string]) {
        throw [System.IO.InvalidDataException]::new("Invalid source CSV row evidence for $($Output.sourceFile).")
    }
    try {
        $identity = Get-AvmCatalogLegacyIdentity -Row @{
            ModuleName = $Row.moduleName
            RepoURL = $Row.repoURL
        } -Ecosystem $Output.ecosystem -Configuration $Configuration
        if ($identity.ModuleType -cne $Output.moduleType) {
            throw [System.ArgumentException]::new('Module kind disagrees with its CSV.')
        }
        return $identity.Key
    }
    catch [System.ArgumentException] {
        if ($RequireResolved) {
            throw [System.IO.InvalidDataException]::new("Generated CSV row has an invalid identity: $($Output.sourceFile), $($Row.moduleName).", $_.Exception)
        }
        return 'unresolved:' + (ConvertTo-Json -InputObject @($Row.moduleName, $Row.repoURL) -Compress)
    }
}

function Get-AvmCatalogCsvRowRemovals {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $SourceRows,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $OutputRows,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Output,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration
    )

    $generated = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $OutputRows) {
        $key = Get-AvmCatalogCsvRowKey -Row $row -Output $Output -Configuration $Configuration -RequireResolved
        if (-not $generated.Add($key)) {
            throw [System.IO.InvalidDataException]::new("Duplicate generated CSV row identity: $($Output.sourceFile), $($row.moduleName).")
        }
    }
    $source = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $removed = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $SourceRows) {
        $key = Get-AvmCatalogCsvRowKey -Row $row -Output $Output -Configuration $Configuration
        if (-not $source.Add($key)) {
            throw [System.IO.InvalidDataException]::new("Duplicate source CSV row identity: $($Output.sourceFile), $($row.moduleName).")
        }
        if (-not $generated.Contains($key)) {
            $removed.Add([ordered]@{
                    sourceFile = $Output.sourceFile
                    moduleName = $row.moduleName
                    repoURL = $row.repoURL
                })
        }
    }
    return ,$removed.ToArray()
}

function Select-AvmCatalogCsvRowRemoval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Removals,
        [AllowEmptyCollection()][object[]] $Renames = @(),
        [System.Collections.Generic.HashSet[string]] $ExcludedModuleKeys,
        [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration)
    )

    if ($Renames.Count -eq 0 -and ($null -eq $ExcludedModuleKeys -or $ExcludedModuleKeys.Count -eq 0)) {
        return , $Removals
    }
    $renamed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($rename in $Renames) {
        $null = $renamed.Add(('{0}|{1}|{2}' -f [string]$rename.sourceFile, [string]$rename.moduleName, [string]$rename.fromRepoURL))
    }
    $outputs = @{}
    foreach ($output in $Configuration.outputs | Where-Object kind -eq 'csv') {
        $outputs[$output.sourceFile] = $output
    }
    return , @($Removals | Where-Object {
            if ($renamed.Contains(('{0}|{1}|{2}' -f [string]$_.sourceFile, [string]$_.moduleName, [string]$_.repoURL))) {
                return $false
            }
            if ($null -ne $ExcludedModuleKeys -and $ExcludedModuleKeys.Count -gt 0) {
                $key = Get-AvmCatalogCsvRowKey -Row @{ moduleName = $_.moduleName; repoURL = $_.repoURL } `
                    -Output $outputs[$_.sourceFile] -Configuration $Configuration
                return -not $ExcludedModuleKeys.Contains($key)
            }
            return $true
        })
}

function Get-AvmCatalogCsvRowRemovalReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Removal,
        [System.Collections.IDictionary] $Reasons
    )

    $key = '{0}|{1}' -f [string]$Removal.sourceFile, [string]$Removal.moduleName
    if ($null -ne $Reasons -and $Reasons.Contains($key)) {
        return [string]$Reasons[$key]
    }
    return 'unknown'
}

function Format-AvmCatalogCsvRowRemoval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Removals,
        [System.Collections.IDictionary] $Reasons
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $files = @($Removals | ForEach-Object { [string]$_.sourceFile } | Sort-Object -Unique)
    foreach ($file in $files) {
        $rows = @($Removals | Where-Object { [string]$_.sourceFile -eq $file })
        $lines.Add('')
        $lines.Add("  $file  -  $($rows.Count) row(s)")
        $lines.Add('  ' + ('-' * ($file.Length + 18)))
        $width = (@($rows | ForEach-Object { ([string]$_.moduleName).Length }) | Measure-Object -Maximum).Maximum
        $reasonWidth = (@($rows | ForEach-Object { (Get-AvmCatalogCsvRowRemovalReason -Removal $_ -Reasons $Reasons).Length }) | Measure-Object -Maximum).Maximum
        foreach ($row in ($rows | Sort-Object { [string]$_.moduleName })) {
            $reason = Get-AvmCatalogCsvRowRemovalReason -Removal $row -Reasons $Reasons
            $lines.Add(('    {0}  {1}  {2}' -f ([string]$row.moduleName).PadRight($width), $reason.PadRight($reasonWidth), [string]$row.repoURL))
        }
    }
    return ($lines -join "`n")
}

function Write-AvmCatalogCsvRowRemovalReport {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Removals,
        [Parameter(Mandatory)][string] $Path,
        [System.Collections.IDictionary] $Reasons,
        [AllowEmptyCollection()][object[]] $Renames = @(),
        [AllowEmptyCollection()][string[]] $HeldBackOutput = @(),
        [switch] $Forced
    )

    $destination = [System.IO.Path]::GetFullPath($Path)
    if (-not $PSCmdlet.ShouldProcess($destination, 'Write the source CSV row-removal diagnostics report')) {
        return
    }
    $null = [System.IO.Directory]::CreateDirectory($destination)

    $byFile = [ordered]@{}
    foreach ($removal in $Removals) {
        $file = [string]$removal.sourceFile
        if (-not $byFile.Contains($file)) {
            $byFile[$file] = 0
        }
        $byFile[$file] += 1
    }
    $report = [ordered]@{
        generatedAt = [datetime]::UtcNow.ToString('o')
        removalCount = $Removals.Count
        removalsForced = [bool]$Forced
        removalsBySourceFile = $byFile
        heldBackSourceFiles = @($HeldBackOutput)
        renames = @($Renames)
        removals = @(foreach ($removal in $Removals) {
                [ordered]@{
                    sourceFile = [string]$removal.sourceFile
                    moduleName = [string]$removal.moduleName
                    repoURL = [string]$removal.repoURL
                    reason = Get-AvmCatalogCsvRowRemovalReason -Removal $removal -Reasons $Reasons
                }
            })
    }
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Join-Path $destination 'csv-row-removals.json'),
        (ConvertTo-AvmCatalogJson -Value $report), $encoding)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($removal in $Removals) {
        $rows.Add([ordered]@{
                SourceFile = [string]$removal.sourceFile
                ModuleName = [string]$removal.moduleName
                RepoURL = [string]$removal.repoURL
                Reason = Get-AvmCatalogCsvRowRemovalReason -Removal $removal -Reasons $Reasons
                Published = if ([string]$removal.sourceFile -in $HeldBackOutput -or -not $Forced) { 'no' } else { 'yes' }
            })
    }
    [System.IO.File]::WriteAllText((Join-Path $destination 'csv-row-removals.csv'),
        (ConvertTo-AvmCatalogCsv -Headers @('SourceFile', 'ModuleName', 'RepoURL', 'Reason', 'Published') -Rows $rows.ToArray()), $encoding)

    return $destination
}

function Resolve-AvmCatalogCsvRowRetention {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Removals,
        [AllowEmptyCollection()][object[]] $Renames = @(),
        [System.Collections.IDictionary] $Reasons,
        [switch] $Force,
        [string] $DiagnosticsPath
    )

    $heldBack = @($Removals | ForEach-Object { [string]$_.sourceFile } | Sort-Object -Unique)
    if ($Force) {
        $heldBack = @()
    }
    if ($DiagnosticsPath) {
        $written = Write-AvmCatalogCsvRowRemovalReport -Removals $Removals -Path $DiagnosticsPath -Reasons $Reasons `
            -Renames $Renames -HeldBackOutput $heldBack -Forced:$Force -Confirm:$false
        Write-AvmCatalogProgress ("CSV row-removal report written to {0} ({1} row(s))." -f $written, $Removals.Count)
    }
    if ($Renames.Count -gt 0) {
        Write-AvmCatalogProgress ("{0} row(s) followed a repository move and were updated in place." -f $Renames.Count)
        foreach ($rename in $Renames) {
            Write-AvmCatalogProgress ("  {0}: {1} -> {2}" -f $rename.sourceFile, $rename.fromRepoURL, $rename.toRepoURL)
        }
    }
    if ($Removals.Count -eq 0) {
        return , @()
    }
    $table = Format-AvmCatalogCsvRowRemoval -Removals $Removals -Reasons $Reasons
    Write-AvmCatalogProgress ("{0} row(s) have no matching module source:`n{1}`n" -f $Removals.Count, $table)
    if ($Force) {
        Write-Warning ("Force permits {0} source CSV row removal(s)." -f $Removals.Count)
        return , @()
    }
    Write-AvmCatalogProgress ("Holding back {0} output(s) so no row is lost: {1}" -f $heldBack.Count, ($heldBack -join ', '))
    return , $heldBack
}

function Assert-AvmCatalogCsvRowRetention {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Removals,
        [switch] $Force,
        [string] $DiagnosticsPath,
        [AllowEmptyCollection()][string[]] $HeldBackOutput = @()
    )

    if ($DiagnosticsPath) {
        $written = Write-AvmCatalogCsvRowRemovalReport -Removals $Removals -Path $DiagnosticsPath -HeldBackOutput $HeldBackOutput -Forced:$Force -Confirm:$false
        Write-AvmCatalogProgress ("CSV row-removal report written to {0} ({1} row(s))." -f $written, $Removals.Count)
    }
    $blocked = @($Removals | Where-Object { [string]$_.sourceFile -cnotin $HeldBackOutput })
    if ($blocked.Count -eq 0) {
        return
    }
    $table = Format-AvmCatalogCsvRowRemoval -Removals $blocked
    $details = @($blocked | ForEach-Object { "$($_.sourceFile): $($_.moduleName) [$($_.repoURL)]" }) -join "`n"
    Write-AvmCatalogProgress ("{0} row(s) would be removed from source CSVs:`n{1}`n" -f $blocked.Count, $table)
    if (-not $Force) {
        throw [System.IO.InvalidDataException]::new(
            "$($blocked.Count) row(s) would be removed from source CSVs:`n$details`nCSV row removals are blocked. Use -Force (workflow force=true) only to permit these removals.")
    }
    Write-Warning "Force permits these source CSV row removals:`n$details"
}

function Write-AvmCatalogMissingOwner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Defects,
        [switch] $Force,
        [string] $DiagnosticsPath
    )

    if ($Defects.Count -eq 0) {
        return
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @($Defects | ForEach-Object { [string]$_.sourceFile } | Sort-Object -Unique)) {
        $rows = @($Defects | Where-Object { [string]$_.sourceFile -eq $file })
        $lines.Add('')
        $lines.Add("  $file  -  $($rows.Count) module(s)")
        $lines.Add('  ' + ('-' * ($file.Length + 20)))
        $width = (@($rows | ForEach-Object { ([string]$_.moduleName).Length }) | Measure-Object -Maximum).Maximum
        foreach ($row in ($rows | Sort-Object { [string]$_.moduleName })) {
            $lines.Add(('    {0}  {1}' -f ([string]$row.moduleName).PadRight($width), (@($row.owners) -join ', ')))
        }
    }
    Write-AvmCatalogProgress ("{0} module(s) name a GitHub owner that no longer exists:`n{1}`n" -f $Defects.Count, ($lines -join "`n"))
    if ($DiagnosticsPath) {
        $destination = [System.IO.Path]::GetFullPath($DiagnosticsPath)
        $null = [System.IO.Directory]::CreateDirectory($destination)
        $encoding = [System.Text.UTF8Encoding]::new($false)
        $report = [ordered]@{
            generatedAt = [datetime]::UtcNow.ToString('o')
            missingOwnerCount = $Defects.Count
            missingOwnersForced = [bool]$Force
            missingOwners = @($Defects)
        }
        [System.IO.File]::WriteAllText((Join-Path $destination 'missing-owners.json'),
            (ConvertTo-AvmCatalogJson -Value $report), $encoding)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($defect in $Defects) {
            $rows.Add([ordered]@{
                    SourceFile = [string]$defect.sourceFile
                    ModuleName = [string]$defect.moduleName
                    RepoURL = [string]$defect.repoURL
                    MissingOwners = (@($defect.owners) -join ' ')
                    Published = if ($Force) { 'yes' } else { 'no' }
                })
        }
        [System.IO.File]::WriteAllText((Join-Path $destination 'missing-owners.csv'),
            (ConvertTo-AvmCatalogCsv -Headers @('SourceFile', 'ModuleName', 'RepoURL', 'MissingOwners', 'Published') -Rows $rows.ToArray()), $encoding)
        Write-AvmCatalogProgress ("Missing-owner report written to {0} ({1} module(s))." -f $destination, $Defects.Count)
    }
    if ($Force) {
        Write-Warning ("Force permits publishing {0} module(s) whose GitHub owner no longer exists." -f $Defects.Count)
        return
    }
    Write-AvmCatalogProgress ("Holding back the affected CSV file(s) until the owners are corrected: {0}" -f
        ((@($Defects | ForEach-Object { [string]$_.sourceFile } | Sort-Object -Unique)) -join ', '))
}