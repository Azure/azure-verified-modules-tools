function Test-AvmToolsLock {
    <#
    .SYNOPSIS
        Validate a hashtable that purports to be an Avm tools lock.

    .DESCRIPTION
        Throws [System.Data.DataException] with a precise message when the
        lock fails the schema. Returns $true on success so it can be used in
        an assertion-style call (`Test-AvmToolsLock $lock | Out-Null`).

        Schema rules are documented at the head of Resources/tools.lock.psd1.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [hashtable] $Lock,

        # Test-only escape hatch. When set, urlTemplate values may also start
        # with file:// (used by fixture locks under tests/fixtures/tools/).
        [switch] $AllowFileUrls
    )

    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
    }

    process {
        if (-not $Lock.ContainsKey('schemaVersion')) {
            throw [System.Data.DataException]::new("tools.lock: missing 'schemaVersion'.")
        }
        if ($Lock.schemaVersion -ne 1) {
            throw [System.Data.DataException]::new(
                "tools.lock: unsupported schemaVersion '$($Lock.schemaVersion)'. Expected 1.")
        }
        if (-not $Lock.ContainsKey('tools')) {
            throw [System.Data.DataException]::new("tools.lock: missing 'tools' array.")
        }

        $tools = @($Lock.tools)
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
                    "tools.lock: tool[$i] is not a hashtable.")
            }

            foreach ($k in 'name', 'version', 'urlTemplate', 'archive', 'entrypoint', 'sha256') {
                if (-not $t.ContainsKey($k)) {
                    throw [System.Data.DataException]::new(
                        "tools.lock: tool[$i] is missing required key '$k'.")
                }
            }

            if ($t.name -notmatch $nameRegex) {
                throw [System.Data.DataException]::new(
                    "tools.lock: tool[$i].name '$($t.name)' must be lowercase kebab-case.")
            }
            if (-not $seenNames.Add($t.name)) {
                throw [System.Data.DataException]::new(
                    "tools.lock: duplicate tool name '$($t.name)'.")
            }
            if ($t.version -notmatch $semverRegex) {
                throw [System.Data.DataException]::new(
                    "tools.lock: tool[$i].version '$($t.version)' is not semver.")
            }
            if (-not $t.urlTemplate.StartsWith('https://')) {
                if (-not ($AllowFileUrls -and $t.urlTemplate.StartsWith('file://'))) {
                    throw [System.Data.DataException]::new(
                        "tools.lock: tool[$i].urlTemplate must start with 'https://'.")
                }
            }
            if ($archives -cnotcontains $t.archive) {
                throw [System.Data.DataException]::new(
                    "tools.lock: tool[$i].archive '$($t.archive)' is not one of: $($archives -join ', ').")
            }
            if ($t.entrypoint -cne $t.entrypoint.ToLowerInvariant()) {
                throw [System.Data.DataException]::new(
                    "tools.lock: tool[$i].entrypoint must be lowercase.")
            }

            $sha = $t.sha256
            if ($sha -isnot [hashtable]) {
                throw [System.Data.DataException]::new(
                    "tools.lock: tool[$i].sha256 must be a hashtable.")
            }

            $unsupported = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            if ($t.ContainsKey('unsupportedPlatforms')) {
                $list = @($t.unsupportedPlatforms)
                foreach ($p in $list) {
                    if ($platforms -cnotcontains $p) {
                        throw [System.Data.DataException]::new(
                            "tools.lock: tool[$i].unsupportedPlatforms contains unknown platform '$p'.")
                    }
                    $null = $unsupported.Add($p)
                }
                if ($unsupported.Count -eq $platforms.Count) {
                    throw [System.Data.DataException]::new(
                        "tools.lock: tool[$i].unsupportedPlatforms marks every platform unsupported; remove the tool instead.")
                }
            }

            foreach ($p in $platforms) {
                if ($unsupported.Contains($p)) {
                    if ($sha.ContainsKey($p)) {
                        throw [System.Data.DataException]::new(
                            "tools.lock: tool[$i].sha256 has entry for '$p' but the platform is listed in unsupportedPlatforms.")
                    }
                    continue
                }
                if (-not $sha.ContainsKey($p)) {
                    throw [System.Data.DataException]::new(
                        "tools.lock: tool[$i].sha256 missing platform '$p'.")
                }
                if ($sha[$p] -notmatch $sha256Regex) {
                    throw [System.Data.DataException]::new(
                        "tools.lock: tool[$i].sha256['$p'] is not 64-char lowercase hex.")
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
                        "tools.lock: tool[$i].platformAliases must be a hashtable.")
                }
                foreach ($p in $platforms) {
                    if ($unsupported.Contains($p)) {
                        if ($aliases.ContainsKey($p)) {
                            throw [System.Data.DataException]::new(
                                "tools.lock: tool[$i].platformAliases has entry for '$p' but the platform is listed in unsupportedPlatforms.")
                        }
                        continue
                    }
                    if (-not $aliases.ContainsKey($p)) {
                        throw [System.Data.DataException]::new(
                            "tools.lock: tool[$i].platformAliases missing platform '$p'.")
                    }
                    if ([string]::IsNullOrWhiteSpace([string]$aliases[$p])) {
                        throw [System.Data.DataException]::new(
                            "tools.lock: tool[$i].platformAliases['$p'] is empty.")
                    }
                }
            }
            elseif ($usesPlatform) {
                throw [System.Data.DataException]::new(
                    "tools.lock: tool[$i].urlTemplate uses '{platform}' but no platformAliases map is defined.")
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
                        "tools.lock: tool[$i].archives must be a hashtable.")
                }
                foreach ($p in $platforms) {
                    if ($unsupported.Contains($p)) {
                        if ($archMap.ContainsKey($p)) {
                            throw [System.Data.DataException]::new(
                                "tools.lock: tool[$i].archives has entry for '$p' but the platform is listed in unsupportedPlatforms.")
                        }
                        continue
                    }
                    if (-not $archMap.ContainsKey($p)) {
                        throw [System.Data.DataException]::new(
                            "tools.lock: tool[$i].archives missing platform '$p'.")
                    }
                    if ($archives -cnotcontains $archMap[$p]) {
                        throw [System.Data.DataException]::new(
                            "tools.lock: tool[$i].archives['$p'] '$($archMap[$p])' is not one of: $($archives -join ', ').")
                    }
                }
            }
        }

        return $true
    }
}
