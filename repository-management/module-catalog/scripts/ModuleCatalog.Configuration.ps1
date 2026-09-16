function Assert-AvmCatalogManifestKeys {
    param([object] $Value, [string[]] $Keys)

    if ($Value -isnot [System.Collections.IDictionary] -or $Value.Count -ne $Keys.Count -or
        @($Value.Keys | Where-Object { $_ -cnotin $Keys }).Count -gt 0) {
        throw [System.IO.InvalidDataException]::new("Catalog manifest fields must be exactly: $($Keys -join ', ').")
    }
}

function Assert-AvmCatalogManifestPath {
    param([Parameter(Mandatory)][string] $Path)

    if ($Path -cnotmatch '^[A-Za-z0-9._/-]+$' -or $Path.StartsWith('/') -or
        @($Path.Split('/') | Where-Object {
                $_ -in @('', '.', '..') -or $_.StartsWith('.') -or $_.EndsWith('.') -or
                $_ -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)'
            }).Count -gt 0) {
        throw [System.IO.InvalidDataException]::new("Unsafe catalog manifest path: $Path")
    }
}

function Read-AvmCatalogConfiguration {
    [CmdletBinding()]
    param([string] $Path = (Join-Path $PSScriptRoot '..' 'config.json'))

    $configuration = Read-AvmCatalogJson -Path $Path
    Assert-AvmCatalogManifestKeys -Value $configuration -Keys @('schemaVersion', 'repositories', 'destinations', 'outputs')
    if (($configuration.schemaVersion -isnot [int] -and $configuration.schemaVersion -isnot [long]) -or $configuration.schemaVersion -ne 1 -or
        $configuration.repositories -isnot [System.Collections.IDictionary] -or
        $configuration.destinations -isnot [System.Collections.IDictionary] -or
        $configuration.outputs -isnot [array]) {
        throw [System.IO.InvalidDataException]::new('Invalid catalog manifest: expected v1 repositories, destinations, and outputs.')
    }
    Assert-AvmCatalogManifestKeys -Value $configuration.repositories -Keys @('docs', 'bicep', 'tools')
    Assert-AvmCatalogManifestKeys -Value $configuration.destinations -Keys @('docs')
    $repositories = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($role in @('docs', 'bicep', 'tools')) {
        $repository = $configuration.repositories[$role]
        if ($repository -isnot [string] -or $repository -cnotmatch '^Azure/[A-Za-z0-9][A-Za-z0-9_.-]*$' -or
            -not $repositories.Add($repository)) {
            throw [System.IO.InvalidDataException]::new("Catalog repository '$role' must be a distinct Azure/owner-repository name.")
        }
    }
    foreach ($role in @('docs')) {
        $destination = $configuration.destinations[$role]
        Assert-AvmCatalogManifestKeys -Value $destination -Keys @('repository', 'path')
        if ($destination -isnot [System.Collections.IDictionary] -or $destination.repository -cne $role -or $destination.path -isnot [string]) {
            throw [System.IO.InvalidDataException]::new("Invalid catalog destination '$role'.")
        }
        Assert-AvmCatalogManifestPath -Path $destination.path
        $prefix = 'docs/'
        if (-not $destination.path.StartsWith($prefix, [StringComparison]::Ordinal)) {
            throw [System.IO.InvalidDataException]::new("Catalog destination '$role' must remain under '$prefix'.")
        }
    }

    $kinds = @('csv', 'mar', 'catalog', 'migration-report', 'publication-plan')
    $counts = @{}
    $csvKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $csvSources = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $bundlePaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $targetPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $basePaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($output in $configuration.outputs) {
        if ($output -isnot [System.Collections.IDictionary] -or $output.kind -cnotin $kinds -or $output.file -isnot [string]) {
            throw [System.IO.InvalidDataException]::new('Each catalog output requires a supported kind and relative filename.')
        }
        $keys = @('kind', 'file', 'destination')
        if ($output.kind -ceq 'csv') { $keys += @('sourceFile', 'ecosystem', 'moduleType') }
        if ($output.kind -ceq 'catalog') { $keys += 'schema' }
        Assert-AvmCatalogManifestKeys -Value $output -Keys $keys
        Assert-AvmCatalogManifestPath -Path $output.file
        $kind = $output.kind
        $counts[$kind] = 1 + [int]$counts[$kind]
        $extension = if ($kind -eq 'csv') { '.csv' } else { '.json' }
        if (-not $output.file.EndsWith($extension, [StringComparison]::Ordinal)) {
            throw [System.IO.InvalidDataException]::new("Catalog output '$kind' requires a $extension filename.")
        }
        if ($kind -eq 'csv') {
            if ($output.sourceFile -isnot [string] -or
                -not $output.sourceFile.EndsWith('.csv', [StringComparison]::Ordinal) -or
                -not $csvSources.Add($output.sourceFile)) {
                throw [System.IO.InvalidDataException]::new('Catalog CSV sources require distinct relative .csv filenames.')
            }
            Assert-AvmCatalogManifestPath -Path $output.sourceFile
            if ($output.ecosystem -cnotin @('bicep', 'terraform') -or $output.moduleType -cnotin @('resource', 'pattern', 'utility') -or
                -not $csvKeys.Add("$($output.ecosystem)/$($output.moduleType)")) {
                throw [System.IO.InvalidDataException]::new('Duplicate or invalid catalog CSV ecosystem/module-type mapping.')
            }
        }
        $expectedDestination = if ($kind -eq 'publication-plan') { $null } else { 'docs' }
        if (-not $output.Contains('destination') -or $output.destination -cne $expectedDestination) {
            throw [System.IO.InvalidDataException]::new("Catalog output '$kind' has an invalid destination.")
        }
        $output['bundlePath'] = if ($null -eq $expectedDestination) { $output.file } else { "$expectedDestination/$($output.file)" }
        $output['targetPath'] = if ($null -ne $expectedDestination) { "$($configuration.destinations[$expectedDestination].path)/$($output.file)" } else { $null }
        $output['repository'] = if ($null -ne $expectedDestination) { $configuration.repositories[$expectedDestination] } else { $null }
        if ($kind -eq 'csv') {
            $output['sourcePath'] = "$($configuration.destinations[$expectedDestination].path)/$($output.sourceFile)"
            $null = $basePaths.Add("$($output.repository)/$($output.sourcePath)")
        }
        if (-not $bundlePaths.Add($output.bundlePath) -or
            ($null -ne $output.targetPath -and -not $targetPaths.Add("$($output.repository)/$($output.targetPath)"))) {
            throw [System.IO.InvalidDataException]::new('Catalog outputs contain duplicate bundle or publication paths.')
        }
        if ($null -ne $output.targetPath) {
            $null = $basePaths.Add("$($output.repository)/$($output.targetPath)")
        }
        if ($kind -eq 'catalog') {
            if ($output['schema'] -isnot [string]) {
                throw [System.IO.InvalidDataException]::new('The catalog output requires its packaged schema path.')
            }
            Assert-AvmCatalogManifestPath -Path $output.schema
            if (-not $output.schema.StartsWith('src/Avm.Authoring/Resources/Schemas/', [StringComparison]::Ordinal)) {
                throw [System.IO.InvalidDataException]::new('The catalog schema must come from the trusted packaged schemas.')
            }
        }
    }
    foreach ($kind in $kinds) {
        $expected = if ($kind -eq 'csv') { 6 } else { 1 }
        if ($counts[$kind] -ne $expected) {
            throw [System.IO.InvalidDataException]::new("Catalog manifest requires exactly $expected '$kind' output(s).")
        }
    }
    foreach ($paths in @($bundlePaths, $basePaths)) {
        foreach ($candidatePath in $paths) {
            if (@($paths | Where-Object { $_.StartsWith("$candidatePath/", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
                throw [System.IO.InvalidDataException]::new("Catalog output file/directory paths collide: $candidatePath")
            }
        }
    }
    $configuration['hash'] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $configuration
}

function Get-AvmCatalogOutput {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][string] $Kind
    )

    $outputs = @($Configuration.outputs | Where-Object { $_.kind -ceq $Kind })
    if ($outputs.Count -ne 1) {
        throw [System.IO.InvalidDataException]::new("Expected one configured '$Kind' output.")
    }
    return $outputs[0]
}

function Get-AvmCatalogPublicationPaths {
    [CmdletBinding()]
    param([System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration))

    $paths = [ordered]@{}
    foreach ($role in $Configuration.destinations.Keys) {
        $files = [ordered]@{}
        $basePaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($output in $Configuration.outputs | Where-Object { $_.destination -ceq $role }) {
            $files[$output.bundlePath] = $output.targetPath
            $null = $basePaths.Add($output.targetPath)
            if ($output.kind -ceq 'csv') {
                $null = $basePaths.Add($output.sourcePath)
            }
        }
        $paths[$role] = [ordered]@{
            repository = $Configuration.repositories[$role]
            files = $files
            basePaths = Get-AvmCatalogOrdinal -Values @($basePaths)
        }
    }
    return $paths
}
