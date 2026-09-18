#Requires -Version 7.4

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Assert-AvmCatalogSafePath {
    [CmdletBinding()]
    param([string] $Root, [string] $RelativePath)

    if ($RelativePath -notmatch '^[A-Za-z0-9._/-]+$' -or $RelativePath.StartsWith('/') -or
        @($RelativePath.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw [System.IO.InvalidDataException]::new('Publication paths must be fixed relative file paths.')
    }
    $current = [System.IO.Path]::GetFullPath($Root)
    foreach ($segment in @('') + $RelativePath.Split('/')) {
        if ($segment) {
            $current = Join-Path $current $segment
        }
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw [System.IO.InvalidDataException]::new("Publication refuses linked paths: $RelativePath")
            }
        }
    }
}

function Test-AvmCatalogPublicationBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration),
        [switch] $Force,
        [string] $DiagnosticsPath
    )

    $paths = Get-AvmCatalogPublicationPaths -Configuration $Configuration
    $planOutput = Get-AvmCatalogOutput -Configuration $Configuration -Kind publication-plan
    Assert-AvmCatalogSafePath -Root $Path -RelativePath $planOutput.bundlePath
    $plan = Read-AvmCatalogJson -Path (Join-Path $Path $planOutput.bundlePath)
    Assert-AvmCatalogManifestKeys -Value $plan -Keys (@('schemaVersion', 'manifestHash', 'outputHashes') + @($paths.Keys))
    if ($plan.schemaVersion -ne 1 -or $plan['manifestHash'] -cne $Configuration.hash) {
        throw [System.IO.InvalidDataException]::new('Unsupported or stale catalog publication manifest. Collect and generate again.')
    }
    $expected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($role in $paths.Keys) {
        if ($plan[$role].repository -cne $paths[$role].repository -or
            $plan[$role].baseFiles.Count -ne $paths[$role].basePaths.Count) {
            throw [System.IO.InvalidDataException]::new("Unexpected publication target: $role")
        }
        foreach ($target in $paths[$role].basePaths) {
            if (-not $plan[$role].baseFiles.Contains($target) -or
                ($null -ne $plan[$role].baseFiles[$target] -and $plan[$role].baseFiles[$target] -cnotmatch '^[0-9a-f]{64}$')) {
                throw [System.IO.InvalidDataException]::new("Publication plan has no valid base hash for $target.")
            }
        }
        foreach ($relative in $paths[$role].files.Keys) {
            $null = $expected.Add($relative)
            Assert-AvmCatalogSafePath -Root $Path -RelativePath $relative
            $file = Join-Path $Path $relative
            if (-not $plan.outputHashes.Contains($relative) -or
                (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $plan.outputHashes[$relative]) {
                throw [System.Security.SecurityException]::new("Catalog output hash mismatch: $relative")
            }
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            if ($text.Contains("`r") -or $text.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)) {
                throw [System.IO.InvalidDataException]::new("Catalog publication requires LF UTF-8 without BOM: $relative")
            }
            if ($relative.EndsWith('.csv', [StringComparison]::Ordinal)) {
                $null = Read-AvmCatalogCsv -Path $file
            }
            else {
                $null = Read-AvmCatalogJson -Path $file
            }
        }
    }
    if ($plan.outputHashes.Count -ne $expected.Count) {
        throw [System.IO.InvalidDataException]::new('Catalog plan includes unexpected output hashes.')
    }
    $null = $expected.Add($planOutput.bundlePath)
    $actual = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force)
    foreach ($file in $actual) {
        $relative = [System.IO.Path]::GetRelativePath($Path, $file.FullName).Replace('\', '/')
        if (-not $expected.Contains($relative)) {
            throw [System.IO.InvalidDataException]::new("Unexpected file in publication bundle: $relative")
        }
    }
    if ($actual.Count -ne $expected.Count) {
        throw [System.IO.InvalidDataException]::new('Publication bundle is incomplete.')
    }
    $catalogOutput = Get-AvmCatalogOutput -Configuration $Configuration -Kind catalog
    $schemaPath = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))) $catalogOutput.schema
    $catalog = [System.IO.File]::ReadAllText((Join-Path $Path $catalogOutput.bundlePath))
    if (-not (Test-Json -Json $catalog -SchemaFile $schemaPath -ErrorAction Stop)) {
        throw [System.IO.InvalidDataException]::new('Publication catalog does not conform to the packaged output schema.')
    }
    $removals = Get-AvmCatalogPublicationRowRemovals -BundlePath $Path -Configuration $Configuration
    Assert-AvmCatalogCsvRowRetention -Removals $removals -Force:$Force -DiagnosticsPath $DiagnosticsPath `
        -HeldBackOutput (Get-AvmCatalogPublicationHeldBackSourceFile -BundlePath $Path -Configuration $Configuration)
    return $plan
}

function Get-AvmCatalogPublicationHeldBackSourceFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $BundlePath,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration
    )

    $reportOutput = Get-AvmCatalogOutput -Configuration $Configuration -Kind migration-report
    $report = Read-AvmCatalogJson -Path (Join-Path $BundlePath $reportOutput.bundlePath)
    if ($report -isnot [System.Collections.IDictionary] -or -not $report.Contains('heldBackSourceFiles') -or
        $report.heldBackSourceFiles -isnot [array]) {
        return , @()
    }
    return , @($report.heldBackSourceFiles | ForEach-Object { [string]$_ })
}

function Get-AvmCatalogHeldBackOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [AllowEmptyCollection()][string[]] $SourceFile = @()
    )

    if ($SourceFile.Count -eq 0) {
        return , @()
    }
    $held = [System.Collections.Generic.List[string]]::new()
    foreach ($output in @($Configuration.outputs | Where-Object { $_.kind -ceq 'csv' })) {
        if ([string]$output.sourceFile -cin $SourceFile) {
            $held.Add([string]$output.bundlePath)
        }
    }
    $held.Add([string](Get-AvmCatalogOutput -Configuration $Configuration -Kind catalog).bundlePath)
    return , $held.ToArray()
}

function Get-AvmCatalogPublicationRowRemovals {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $BundlePath,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [string] $SourceRoot
    )

    $reportOutput = Get-AvmCatalogOutput -Configuration $Configuration -Kind migration-report
    $report = Read-AvmCatalogJson -Path (Join-Path $BundlePath $reportOutput.bundlePath)
    if ($report -isnot [System.Collections.IDictionary] -or
        -not $report.Contains('sourceCsvRows') -or -not $report.Contains('csvRowRemovals') -or
        -not $report.Contains('csvRowRemovalsForced') -or $report.csvRowRemovals -isnot [array] -or
        $report.csvRowRemovalsForced -isnot [bool]) {
        throw [System.IO.InvalidDataException]::new('Catalog publication requires source CSV row evidence. Collect and generate again.')
    }
    $outputs = @($Configuration.outputs | Where-Object kind -eq 'csv')
    Assert-AvmCatalogManifestKeys -Value $report.sourceCsvRows -Keys @($outputs.sourceFile)
    $removals = [System.Collections.Generic.List[object]]::new()
    foreach ($output in $outputs) {
        $sourceRows = $report.sourceCsvRows[$output.sourceFile]
        if ($sourceRows -isnot [array]) {
            throw [System.IO.InvalidDataException]::new("Source CSV row evidence must be an array: $($output.sourceFile).")
        }
        if ($SourceRoot) {
            Assert-AvmCatalogSafePath -Root $SourceRoot -RelativePath $output.sourcePath
            $source = Read-AvmCatalogCsv -Path (Join-Path $SourceRoot $output.sourcePath)
            $actualRows = Get-AvmCatalogCsvRowSnapshot -Rows $source.Rows.ToArray()
            if ((ConvertTo-AvmCatalogJson -Value $actualRows) -cne (ConvertTo-AvmCatalogJson -Value $sourceRows)) {
                throw [System.Security.SecurityException]::new("Source CSV row evidence does not match the publication base: $($output.sourceFile).")
            }
            $sourceRows = $actualRows
        }
        $generated = Read-AvmCatalogCsv -Path (Join-Path $BundlePath $output.bundlePath)
        $outputRows = Get-AvmCatalogCsvRowSnapshot -Rows $generated.Rows.ToArray()
        foreach ($removal in (Get-AvmCatalogCsvRowRemovals -SourceRows $sourceRows -OutputRows $outputRows `
                -Output $output -Configuration $Configuration)) {
            $removals.Add($removal)
        }
    }
    $renames = @(if ($report.Contains('csvRowRenames') -and $report.csvRowRenames -is [array]) { $report.csvRowRenames })
    $retained = Select-AvmCatalogCsvRowRemoval -Removals $removals.ToArray() -Renames $renames
    $heldBackFiles = @(if ($report.Contains('heldBackSourceFiles') -and $report.heldBackSourceFiles -is [array]) {
            $report.heldBackSourceFiles | ForEach-Object { [string]$_ }
        })
    $blocked = @($retained | Where-Object { [string]$_.sourceFile -cnotin $heldBackFiles })
    if ((ConvertTo-AvmCatalogJson -Value $retained) -cne (ConvertTo-AvmCatalogJson -Value $report.csvRowRemovals) -or
        ($blocked.Count -gt 0 -and -not $report.csvRowRemovalsForced)) {
        throw [System.IO.InvalidDataException]::new('Catalog CSV row-removal report disagrees with its source evidence and generated outputs.')
    }
    return , $retained
}

function Assert-AvmCatalogPublicationBase {
    [CmdletBinding()]
    param([string] $Root, [System.Collections.IDictionary] $BaseFiles)

    foreach ($relative in $BaseFiles.Keys) {
        Assert-AvmCatalogSafePath -Root $Root -RelativePath $relative
        $file = Join-Path $Root $relative
        $hash = if (Test-Path -LiteralPath $file -PathType Leaf) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        if ($hash -cne $BaseFiles[$relative]) {
            throw [System.InvalidOperationException]::new("Publication base changed for $relative. Collect and generate again; stale outputs must not overwrite main.")
        }
    }
}
