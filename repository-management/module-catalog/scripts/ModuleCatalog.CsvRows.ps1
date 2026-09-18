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

function Format-AvmCatalogCsvRowRemoval {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Removals)

    $lines = [System.Collections.Generic.List[string]]::new()
    $files = @($Removals | ForEach-Object { [string]$_.sourceFile } | Sort-Object -Unique)
    foreach ($file in $files) {
        $rows = @($Removals | Where-Object { [string]$_.sourceFile -eq $file })
        $lines.Add('')
        $lines.Add("  $file  -  $($rows.Count) row(s)")
        $lines.Add('  ' + ('-' * ($file.Length + 18)))
        $width = (@($rows | ForEach-Object { ([string]$_.moduleName).Length }) | Measure-Object -Maximum).Maximum
        foreach ($row in ($rows | Sort-Object { [string]$_.moduleName })) {
            $lines.Add(('    {0}  {1}' -f ([string]$row.moduleName).PadRight($width), [string]$row.repoURL))
        }
    }
    return ($lines -join "`n")
}

function Write-AvmCatalogCsvRowRemovalReport {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Removals,
        [Parameter(Mandatory)][string] $Path,
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
        removals = @($Removals)
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
            })
    }
    [System.IO.File]::WriteAllText((Join-Path $destination 'csv-row-removals.csv'),
        (ConvertTo-AvmCatalogCsv -Headers @('SourceFile', 'ModuleName', 'RepoURL') -Rows $rows.ToArray()), $encoding)

    return $destination
}

function Assert-AvmCatalogCsvRowRetention {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Removals,
        [switch] $Force,
        [string] $DiagnosticsPath
    )

    if ($DiagnosticsPath) {
        $written = Write-AvmCatalogCsvRowRemovalReport -Removals $Removals -Path $DiagnosticsPath -Forced:$Force -Confirm:$false
        Write-AvmCatalogProgress ("CSV row-removal report written to {0} ({1} row(s))." -f $written, $Removals.Count)
    }
    if ($Removals.Count -eq 0) {
        return
    }
    $table = Format-AvmCatalogCsvRowRemoval -Removals $Removals
    $details = @($Removals | ForEach-Object { "$($_.sourceFile): $($_.moduleName) [$($_.repoURL)]" }) -join "`n"
    Write-AvmCatalogProgress ("{0} row(s) would be removed from source CSVs:`n{1}`n" -f $Removals.Count, $table)
    if (-not $Force) {
        throw [System.IO.InvalidDataException]::new(
            "$($Removals.Count) row(s) would be removed from source CSVs:`n$details`nCSV row removals are blocked. Use -Force (workflow force=true) only to permit these removals.")
    }
    Write-Warning "Force permits these source CSV row removals:`n$details"
}
