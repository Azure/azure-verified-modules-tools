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

function Assert-AvmCatalogCsvRowRetention {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Removals,
        [switch] $Force
    )

    if ($Removals.Count -eq 0) {
        return
    }
    $details = @($Removals | ForEach-Object { "$($_.sourceFile): $($_.moduleName) [$($_.repoURL)]" }) -join "`n"
    $message = "$($Removals.Count) row(s) would be removed from source CSVs:`n$details"
    if (-not $Force) {
        throw [System.IO.InvalidDataException]::new("$message`nCSV row removals are blocked. Use -Force (workflow force=true) only to permit these removals.")
    }
    Write-Warning "Force permits these source CSV row removals:`n$details"
}
