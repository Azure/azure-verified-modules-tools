function Test-AvmPins {
    <#
    .SYNOPSIS
        Validate a hashtable that purports to be an Avm.Authoring pin manifest.

    .DESCRIPTION
        Throws [System.Data.DataException] with a precise message when the
        manifest fails the schema. Returns $true on success so it can be used in
        an assertion-style call (`Test-AvmPins $pins | Out-Null`).

        Schema rules are documented at the head of Resources/avm.pins.jsonc.

        The 'tools' array is required. The 'policyLibrary' and 'tflintPlugins'
        sections are optional so fixture manifests can pin tools alone, but are
        fully validated whenever present.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Noun mirrors the avm.pins.jsonc manifest, which holds many pins.')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [hashtable] $Pins,

        # Test-only escape hatch. When set, urlTemplate values may also start
        # with file:// (used by fixture manifests under tests/fixtures/tools/).
        [switch] $AllowFileUrls
    )

    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
    }

    process {
        if (-not $Pins.ContainsKey('schemaVersion')) {
            throw [System.Data.DataException]::new("avm.pins: missing 'schemaVersion'.")
        }
        if ($Pins.schemaVersion -ne 1) {
            throw [System.Data.DataException]::new(
                "avm.pins: unsupported schemaVersion '$($Pins.schemaVersion)'. Expected 1.")
        }
        if (-not $Pins.ContainsKey('tools')) {
            throw [System.Data.DataException]::new("avm.pins: missing 'tools' array.")
        }

        $tools = @($Pins.tools)
        $platforms = @('windows-amd64', 'windows-arm64', 'linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64')
        $archives = @('zip', 'tar.gz', 'raw')
        $sha256Regex = '^[0-9a-f]{64}$'
        $nameRegex = '^[a-z][a-z0-9-]*$'
        $semverRegex = '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$'

        $seenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

        for ($i = 0; $i -lt $tools.Count; $i++) {
            $t = $tools[$i]
            if ($t -isnot [hashtable]) {
                throw [System.Data.DataException]::new(
                    "avm.pins: tool[$i] is not an object.")
            }

            foreach ($k in 'name', 'version', 'urlTemplate', 'archive', 'entrypoint', 'sha256') {
                if (-not $t.ContainsKey($k)) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: tool[$i] is missing required key '$k'.")
                }
            }

            if ($t.name -notmatch $nameRegex) {
                throw [System.Data.DataException]::new(
                    "avm.pins: tool[$i].name '$($t.name)' must be lowercase kebab-case.")
            }
            if (-not $seenNames.Add($t.name)) {
                throw [System.Data.DataException]::new(
                    "avm.pins: duplicate tool name '$($t.name)'.")
            }
            if ($t.version -notmatch $semverRegex) {
                throw [System.Data.DataException]::new(
                    "avm.pins: tool[$i].version '$($t.version)' is not semver.")
            }
            if (-not $t.urlTemplate.StartsWith('https://')) {
                if (-not ($AllowFileUrls -and $t.urlTemplate.StartsWith('file://'))) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: tool[$i].urlTemplate must start with 'https://'.")
                }
            }
            if ($archives -cnotcontains $t.archive) {
                throw [System.Data.DataException]::new(
                    "avm.pins: tool[$i].archive '$($t.archive)' is not one of: $($archives -join ', ').")
            }
            if ($t.entrypoint -cne $t.entrypoint.ToLowerInvariant()) {
                throw [System.Data.DataException]::new(
                    "avm.pins: tool[$i].entrypoint must be lowercase.")
            }

            $sha = $t.sha256
            if ($sha -isnot [hashtable]) {
                throw [System.Data.DataException]::new(
                    "avm.pins: tool[$i].sha256 must be an object.")
            }

            $unsupported = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            if ($t.ContainsKey('unsupportedPlatforms')) {
                $list = @($t.unsupportedPlatforms)
                foreach ($p in $list) {
                    if ($platforms -cnotcontains $p) {
                        throw [System.Data.DataException]::new(
                            "avm.pins: tool[$i].unsupportedPlatforms contains unknown platform '$p'.")
                    }
                    $null = $unsupported.Add($p)
                }
                if ($unsupported.Count -eq $platforms.Count) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: tool[$i].unsupportedPlatforms marks every platform unsupported; remove the tool instead.")
                }
            }

            foreach ($p in $platforms) {
                if ($unsupported.Contains($p)) {
                    if ($sha.ContainsKey($p)) {
                        throw [System.Data.DataException]::new(
                            "avm.pins: tool[$i].sha256 has entry for '$p' but the platform is listed in unsupportedPlatforms.")
                    }
                    continue
                }
                if (-not $sha.ContainsKey($p)) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: tool[$i].sha256 missing platform '$p'.")
                }
                if ($sha[$p] -notmatch $sha256Regex) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: tool[$i].sha256['$p'] is not 64-char lowercase hex.")
                }
            }

            # Optional platformAliases: required when urlTemplate references
            # the {platform} placeholder (e.g. bicep, where asset names are
            # 'win-x64.exe', 'osx-arm64', etc. and don't fit {os}_{arch}).
            $usesPlatform = $t.urlTemplate.Contains('{platform}')
            if ($t.ContainsKey('platformAliases')) {
                $aliases = $t.platformAliases
                if ($aliases -isnot [hashtable]) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: tool[$i].platformAliases must be an object.")
                }
                foreach ($p in $platforms) {
                    if ($unsupported.Contains($p)) {
                        if ($aliases.ContainsKey($p)) {
                            throw [System.Data.DataException]::new(
                                "avm.pins: tool[$i].platformAliases has entry for '$p' but the platform is listed in unsupportedPlatforms.")
                        }
                        continue
                    }
                    if (-not $aliases.ContainsKey($p)) {
                        throw [System.Data.DataException]::new(
                            "avm.pins: tool[$i].platformAliases missing platform '$p'.")
                    }
                    if ([string]::IsNullOrWhiteSpace([string]$aliases[$p])) {
                        throw [System.Data.DataException]::new(
                            "avm.pins: tool[$i].platformAliases['$p'] is empty.")
                    }
                }
            }
            elseif ($usesPlatform) {
                throw [System.Data.DataException]::new(
                    "avm.pins: tool[$i].urlTemplate uses '{platform}' but no platformAliases map is defined.")
            }

            # Optional archives map: per-platform archive override. Required
            # for tools whose Windows asset is a .zip while the Unix asset is
            # a .tar.gz (e.g. terraform-docs). When present, every supported
            # platform must be listed and the top-level 'archive' field still
            # acts as the documented default.
            if ($t.ContainsKey('archives')) {
                $archMap = $t.archives
                if ($archMap -isnot [hashtable]) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: tool[$i].archives must be an object.")
                }
                foreach ($p in $platforms) {
                    if ($unsupported.Contains($p)) {
                        if ($archMap.ContainsKey($p)) {
                            throw [System.Data.DataException]::new(
                                "avm.pins: tool[$i].archives has entry for '$p' but the platform is listed in unsupportedPlatforms.")
                        }
                        continue
                    }
                    if (-not $archMap.ContainsKey($p)) {
                        throw [System.Data.DataException]::new(
                            "avm.pins: tool[$i].archives missing platform '$p'.")
                    }
                    if ($archives -cnotcontains $archMap[$p]) {
                        throw [System.Data.DataException]::new(
                            "avm.pins: tool[$i].archives['$p'] '$($archMap[$p])' is not one of: $($archives -join ', ').")
                    }
                }
            }
        }

        if ($Pins.ContainsKey('policyLibrary')) {
            $policy = $Pins.policyLibrary
            if ($policy -isnot [hashtable]) {
                throw [System.Data.DataException]::new(
                    "avm.pins: 'policyLibrary' must be an object.")
            }

            foreach ($k in 'repository', 'ref', 'urlTemplate', 'sha256', 'archiveRoot', 'bundles') {
                if (-not $policy.ContainsKey($k)) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: policyLibrary is missing required key '$k'.")
                }
            }

            if ($policy.repository -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') {
                throw [System.Data.DataException]::new(
                    "avm.pins: policyLibrary.repository '$($policy.repository)' must be '<owner>/<repo>'.")
            }
            if ([string]::IsNullOrWhiteSpace([string]$policy.ref)) {
                throw [System.Data.DataException]::new(
                    "avm.pins: policyLibrary.ref is empty.")
            }
            if (-not $policy.urlTemplate.StartsWith('https://')) {
                if (-not ($AllowFileUrls -and $policy.urlTemplate.StartsWith('file://'))) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: policyLibrary.urlTemplate must start with 'https://'.")
                }
            }
            if ($policy.sha256 -notmatch $sha256Regex) {
                throw [System.Data.DataException]::new(
                    "avm.pins: policyLibrary.sha256 is not 64-char lowercase hex.")
            }
            if ([string]::IsNullOrWhiteSpace([string]$policy.archiveRoot)) {
                throw [System.Data.DataException]::new(
                    "avm.pins: policyLibrary.archiveRoot is empty.")
            }

            $bundles = $policy.bundles
            if ($bundles -isnot [hashtable]) {
                throw [System.Data.DataException]::new(
                    "avm.pins: policyLibrary.bundles must be an object.")
            }
            if ($bundles.Keys.Count -eq 0) {
                throw [System.Data.DataException]::new(
                    "avm.pins: policyLibrary.bundles must define at least one bundle.")
            }
            foreach ($name in $bundles.Keys) {
                if ($name -notmatch $nameRegex) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: policyLibrary.bundles key '$name' must be lowercase kebab-case.")
                }
                $subPath = [string]$bundles[$name]
                if ([string]::IsNullOrWhiteSpace($subPath)) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: policyLibrary.bundles['$name'] is empty.")
                }
                if ($subPath.StartsWith('/') -or $subPath.Contains('..') -or $subPath.Contains('\')) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: policyLibrary.bundles['$name'] must be a relative forward-slash path without '..'.")
                }
            }
        }

        if ($Pins.ContainsKey('tflintPlugins')) {
            $plugins = $Pins.tflintPlugins
            if ($plugins -isnot [hashtable]) {
                throw [System.Data.DataException]::new(
                    "avm.pins: 'tflintPlugins' must be an object.")
            }
            if ($plugins.Keys.Count -eq 0) {
                throw [System.Data.DataException]::new(
                    "avm.pins: tflintPlugins must define at least one plugin.")
            }
            foreach ($name in $plugins.Keys) {
                if ($name -notmatch $nameRegex) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: tflintPlugins key '$name' must be lowercase kebab-case.")
                }
                if ([string]$plugins[$name] -notmatch $semverRegex) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: tflintPlugins['$name'] '$($plugins[$name])' is not semver.")
                }
            }
        }

        if ($Pins.ContainsKey('tflintAvmSchemaSnapshot')) {
            $snapshot = $Pins.tflintAvmSchemaSnapshot
            if ($snapshot -isnot [hashtable]) {
                throw [System.Data.DataException]::new(
                    "avm.pins: 'tflintAvmSchemaSnapshot' must be an object.")
            }
            foreach ($key in 'enabled', 'placeholder', 'version', 'url', 'sha256') {
                if (-not $snapshot.ContainsKey($key)) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: tflintAvmSchemaSnapshot is missing required key '$key'.")
                }
            }
            if ($snapshot.enabled -isnot [bool] -or $snapshot.placeholder -isnot [bool]) {
                throw [System.Data.DataException]::new(
                    'avm.pins: tflintAvmSchemaSnapshot.enabled and .placeholder must be booleans.')
            }
            if ([string]$snapshot.version -notmatch $semverRegex) {
                throw [System.Data.DataException]::new(
                    "avm.pins: tflintAvmSchemaSnapshot.version '$($snapshot.version)' is not semver.")
            }
            if (-not ([string]$snapshot.url).StartsWith('https://')) {
                if (-not ($AllowFileUrls -and ([string]$snapshot.url).StartsWith('file://'))) {
                    throw [System.Data.DataException]::new(
                        "avm.pins: tflintAvmSchemaSnapshot.url must start with 'https://'.")
                }
            }
            if ([string]$snapshot.sha256 -notmatch $sha256Regex) {
                throw [System.Data.DataException]::new(
                    'avm.pins: tflintAvmSchemaSnapshot.sha256 is not 64-char lowercase hex.')
            }
            if ([bool]$snapshot.enabled -and [bool]$snapshot.placeholder) {
                throw [System.Data.DataException]::new(
                    'avm.pins: tflintAvmSchemaSnapshot cannot be enabled while placeholder is true.')
            }
        }

        return $true
    }
}
