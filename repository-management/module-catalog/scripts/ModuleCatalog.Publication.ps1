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
        [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration)
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
    return $plan
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
