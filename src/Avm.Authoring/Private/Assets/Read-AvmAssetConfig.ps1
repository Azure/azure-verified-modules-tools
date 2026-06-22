function Read-AvmAssetConfig {
    <#
    .SYNOPSIS
        Load, merge, and validate the Avm pinned-asset configuration.

    .DESCRIPTION
        Resolves the pinned-asset config that applies to a given on-disk
        location by combining (in increasing precedence):

          1. The per-user config at <Get-AvmFolder Config>/avm.config.json,
             when present.
          2. The nearest .avm/config.json found by walking upward from
             -Path (mirrors Read-AvmContextOverride's directory walk).

        The merge is per-asset: when both layers declare an asset of the
        same name, the per-repo descriptor wins outright (no deep merge).
        Assets unique to either layer pass through unchanged. The result
        is validated against Test-AvmAssetConfig; schema violations are
        rethrown as AvmConfigurationException carrying file context.

        Both files are JSON (ConvertFrom-Json -AsHashtable). When neither
        file is present, returns an empty assets map and an empty source
        map (no exception). The returned shape is:

            [pscustomobject]@{
              Assets  = [ordered]@{ <name> = [pscustomobject] @{ Source = ...; Ref = ...; ... } ; ... }
              Sources = [ordered]@{ <name> = '<full-path-to-config-file>' ; ... }
            }

        Each descriptor pscustomobject has properties (PascalCase to match
        wider module convention): Source, Ref, Sha256, Path, Type. Missing
        optional fields surface as $null.

    .PARAMETER Path
        A directory (or file) to begin the upward walk from. Required.
        Pass the repo root, the working directory, or the path of a module
        under inspection; the function will find the first ancestor that
        contains a .avm/config.json.

    .PARAMETER AllowFileUrls
        Forwarded to Test-AvmAssetConfig. When set, source URLs may also
        start with file:// (used by fixture configs).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [switch] $AllowFileUrls
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $userConfigPath = $null
    $userAssets = $null
    try {
        $configDir = Get-AvmFolder -Kind Config -NoCreate
        $candidate = Join-Path $configDir 'avm.config.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $userConfigPath = (Resolve-Path -LiteralPath $candidate).ProviderPath
            $userAssets = Read-AvmAssetConfigFile -ConfigPath $userConfigPath -AllowFileUrls:$AllowFileUrls
        }
    }
    catch [AvmConfigurationException] {
        throw
    }
    catch {
        # Folder resolution should not be fatal when no per-user config
        # has ever been written; only the parse path uses
        # AvmConfigurationException and that is rethrown above.
        Write-Verbose "Read-AvmAssetConfig: per-user config not loaded: $($_.Exception.Message)"
    }

    $repoConfigPath = $null
    $repoAssets = $null
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $dir = $resolved.ProviderPath
    if ((Get-Item -LiteralPath $dir).PSIsContainer -eq $false) {
        $dir = Split-Path -Parent $dir
    }

    while ($dir) {
        $candidate = Join-Path (Join-Path $dir '.avm') 'config.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $repoConfigPath = (Resolve-Path -LiteralPath $candidate).ProviderPath
            $repoAssets = Read-AvmAssetConfigFile -ConfigPath $repoConfigPath -AllowFileUrls:$AllowFileUrls
            break
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    $mergedAssets = [ordered]@{}
    $mergedSources = [ordered]@{}

    if ($null -ne $userAssets) {
        foreach ($name in $userAssets.Keys) {
            $mergedAssets[$name] = $userAssets[$name]
            $mergedSources[$name] = $userConfigPath
        }
    }
    if ($null -ne $repoAssets) {
        foreach ($name in $repoAssets.Keys) {
            $mergedAssets[$name] = $repoAssets[$name]
            $mergedSources[$name] = $repoConfigPath
        }
    }

    # Re-validate the merged shape so that per-asset overrides cannot
    # accidentally introduce an invalid descriptor that neither layer
    # produced on its own.
    if ($mergedAssets.Count -gt 0) {
        $whole = @{ schemaVersion = 1; assets = $mergedAssets }
        try {
            Test-AvmAssetConfig -Config $whole -AllowFileUrls:$AllowFileUrls | Out-Null
        }
        catch [System.Data.DataException] {
            throw [AvmConfigurationException]::new(
                "Read-AvmAssetConfig: merged config failed validation: $($_.Exception.Message)",
                $_.Exception)
        }
    }

    $assetObjects = [ordered]@{}
    foreach ($name in $mergedAssets.Keys) {
        $d = $mergedAssets[$name]
        $assetObjects[$name] = [pscustomobject][ordered]@{
            Source = [string]$d.source
            Ref    = if ($d.ContainsKey('ref')) { [string]$d.ref } else { $null }
            Sha256 = if ($d.ContainsKey('sha256')) { [string]$d.sha256 } else { $null }
            Path   = if ($d.ContainsKey('path')) { [string]$d.path } else { $null }
            Type   = if ($d.ContainsKey('type')) { [string]$d.type } else { $null }
        }
    }

    return [pscustomobject][ordered]@{
        Assets  = $assetObjects
        Sources = $mergedSources
    }
}

function Read-AvmAssetConfigFile {
    <#
    .SYNOPSIS
        Internal: parse and validate one avm.config.json file.

    .DESCRIPTION
        Loads $ConfigPath as JSON (ConvertFrom-Json -AsHashtable),
        validates it with Test-AvmAssetConfig, and returns the validated
        assets hashtable. Wraps any failure in AvmConfigurationException
        with the file path prefixed for diagnostics.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $ConfigPath,

        [switch] $AllowFileUrls
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8
    }
    catch {
        throw [AvmConfigurationException]::new(
            "${ConfigPath}: unable to read: $($_.Exception.Message)",
            $_.Exception)
    }

    try {
        $parsed = $raw | ConvertFrom-Json -AsHashtable -Depth 16
    }
    catch {
        throw [AvmConfigurationException]::new(
            "${ConfigPath}: invalid JSON: $($_.Exception.Message)",
            $_.Exception)
    }

    if ($parsed -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new(
            "${ConfigPath}: top-level value must be a JSON object.")
    }

    try {
        Test-AvmAssetConfig -Config $parsed -AllowFileUrls:$AllowFileUrls | Out-Null
    }
    catch [System.Data.DataException] {
        throw [AvmConfigurationException]::new(
            "${ConfigPath}: $($_.Exception.Message)",
            $_.Exception)
    }

    if (-not $parsed.Contains('assets')) {
        return @{}
    }
    return $parsed.assets
}
