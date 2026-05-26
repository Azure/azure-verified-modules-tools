function Test-AvmAssetConfig {
    <#
    .SYNOPSIS
        Validate a hashtable that purports to be an Avm pinned-asset config.

    .DESCRIPTION
        Throws [System.Data.DataException] with a precise message when the
        config fails the schema. Returns $true on success so it can be used
        in an assertion-style call (`Test-AvmAssetConfig $cfg | Out-Null`).

        Schema (avm.config.json - pinned-asset slice):

            {
              "schemaVersion": 1,
              "assets": {
                "<name>": {
                  "source":  "https://...",      // required, https://
                  "ref":     "<git-ref-or-sha>", // one of ref or sha256
                  "sha256":  "<64-hex>",         // one of ref or sha256
                  "path":    "<subdir>",         // optional
                  "type":    "git" | "archive"   // optional, inferred
                }
              }
            }

        Notes:
        - Asset names must match ^[a-z][a-z0-9-]*$ (lowercase kebab-case).
        - Either 'ref' or 'sha256' is required; both is allowed (sha256
          will be used to verify the materialised archive at resolve time).
        - 'source' must start with https:// (or file:// when
          -AllowFileUrls is set, used by tests and offline fixtures).
        - 'type' is optional. When omitted, downstream Resolve-AvmPinnedAsset
          infers it from the URL suffix (.tar.gz / .tgz / .zip -> archive,
          everything else -> git).
        - This validator only checks shape. Downloading, materialising,
          and SHA verification are the responsibility of the (separate)
          Resolve-AvmPinnedAsset slice.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [hashtable] $Config,

        # Test-only escape hatch. When set, source values may also start
        # with file:// (used by fixture configs under tests/fixtures/).
        [switch] $AllowFileUrls
    )

    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
    }

    process {
        if (-not $Config.ContainsKey('schemaVersion')) {
            throw [System.Data.DataException]::new("avm.config: missing 'schemaVersion'.")
        }
        if ($Config.schemaVersion -ne 1) {
            throw [System.Data.DataException]::new(
                "avm.config: unsupported schemaVersion '$($Config.schemaVersion)'. Expected 1.")
        }
        if (-not $Config.ContainsKey('assets')) {
            throw [System.Data.DataException]::new("avm.config: missing 'assets' map.")
        }

        $assets = $Config.assets
        if ($assets -isnot [System.Collections.IDictionary]) {
            throw [System.Data.DataException]::new("avm.config: 'assets' must be a hashtable.")
        }

        $nameRegex = '^[a-z][a-z0-9-]*$'
        $sha256Regex = '^[0-9a-f]{64}$'
        $validTypes = @('git', 'archive')
        $knownKeys = @('source', 'ref', 'sha256', 'path', 'type')

        foreach ($name in $assets.Keys) {
            if ($name -cnotmatch $nameRegex) {
                throw [System.Data.DataException]::new(
                    "avm.config: asset name '$name' must be lowercase kebab-case (^[a-z][a-z0-9-]*$).")
            }

            $a = $assets[$name]
            if ($a -isnot [System.Collections.IDictionary]) {
                throw [System.Data.DataException]::new(
                    "avm.config: asset '$name' descriptor must be a hashtable.")
            }

            foreach ($k in $a.Keys) {
                if ($knownKeys -cnotcontains $k) {
                    throw [System.Data.DataException]::new(
                        "avm.config: asset '$name' has unknown key '$k'. Allowed: $($knownKeys -join ', ').")
                }
            }

            if (-not $a.ContainsKey('source')) {
                throw [System.Data.DataException]::new(
                    "avm.config: asset '$name' missing required key 'source'.")
            }
            $source = [string]$a.source
            if ([string]::IsNullOrWhiteSpace($source)) {
                throw [System.Data.DataException]::new(
                    "avm.config: asset '$name' has empty 'source'.")
            }
            if (-not $source.StartsWith('https://')) {
                if (-not ($AllowFileUrls -and $source.StartsWith('file://'))) {
                    throw [System.Data.DataException]::new(
                        "avm.config: asset '$name' source must start with 'https://'.")
                }
            }

            $hasRef = $a.ContainsKey('ref') -and -not [string]::IsNullOrWhiteSpace([string]$a.ref)
            $hasSha = $a.ContainsKey('sha256') -and -not [string]::IsNullOrWhiteSpace([string]$a.sha256)
            if (-not ($hasRef -or $hasSha)) {
                throw [System.Data.DataException]::new(
                    "avm.config: asset '$name' requires one of 'ref' or 'sha256'.")
            }
            if ($hasSha -and ([string]$a.sha256) -cnotmatch $sha256Regex) {
                throw [System.Data.DataException]::new(
                    "avm.config: asset '$name' sha256 must be 64-char lowercase hex.")
            }

            if ($a.ContainsKey('type')) {
                if ($validTypes -cnotcontains $a.type) {
                    throw [System.Data.DataException]::new(
                        "avm.config: asset '$name' type '$($a.type)' is not one of: $($validTypes -join ', ').")
                }
            }

            if ($a.ContainsKey('path') -and [string]::IsNullOrWhiteSpace([string]$a.path)) {
                throw [System.Data.DataException]::new(
                    "avm.config: asset '$name' has empty 'path'.")
            }
        }

        return $true
    }
}
