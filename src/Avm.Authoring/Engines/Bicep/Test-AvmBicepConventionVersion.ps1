function Test-AvmBicepConventionVersion {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        $Scope
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $versionPath = Join-Path $Scope.Path 'version.json'
    $versionFiles = @(Get-ChildItem -LiteralPath $Scope.Path -Force |
            Where-Object { $_.Name -ceq 'version.json' -and -not $_.PSIsContainer })
    if ($versionFiles.Count -eq 0) {
        return $issues.ToArray()
    }

    $json = $null
    try {
        $json = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($versionPath))
    }
    catch [System.Text.Json.JsonException] {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $versionPath `
                    -Code 'avm.bicep.version-invalid' -Line 1 -Message "version.json is invalid JSON: $($_.Exception.Message)"))
    }

    if ($null -ne $json) {
        try {
            $value = [System.Text.Json.JsonElement]::new()
            $valid = $json.RootElement.ValueKind -eq [System.Text.Json.JsonValueKind]::Object -and
            $json.RootElement.TryGetProperty('version', [ref]$value) -and
            $value.ValueKind -eq [System.Text.Json.JsonValueKind]::String -and
            $value.GetString() -cmatch '^[0-9]+\.[0-9]+$'

            if (-not $valid) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $versionPath `
                            -Code 'avm.bicep.version-format' -Line 1 `
                            -Message 'version.json must declare a major.minor version.'))
            }
            elseif ($Scope.ModuleRelativePath -cne 'avm/res/network/nat-gateway') {
                $major = $value.GetString().Split('.')[0].TrimStart('0')
                if ($major.Length -gt 0) {
                    $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $versionPath `
                                -Code 'avm.bicep.version-major' -Line 1 `
                                -Message 'This resource module must not yet use a major version greater than zero.'))
                }
            }
        }
        finally {
            $json.Dispose()
        }
    }

    $changelogPath = Join-Path $Scope.Path 'CHANGELOG.md'
    $changelogFiles = @(Get-ChildItem -LiteralPath $Scope.Path -Force |
            Where-Object { $_.Name -ieq 'CHANGELOG.md' })
    if ($changelogFiles.Count -ne 1 -or $changelogFiles[0].PSIsContainer -or
        $changelogFiles[0].Name -cne 'CHANGELOG.md') {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $changelogPath `
                    -Code 'avm.bicep.changelog-missing' `
                    -Message 'A published module requires a regular CHANGELOG.md with exact casing.'))
        return $issues.ToArray()
    }

    $lines = [System.IO.File]::ReadAllLines($changelogPath)
    if (@($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $changelogPath `
                    -Code 'avm.bicep.changelog-empty' -Line 1 -Message 'CHANGELOG.md must not be empty.'))
        return $issues.ToArray()
    }

    $expectedLink = 'The latest version of the changelog can be found [here](https://github.com/Azure/bicep-registry-modules/blob/main/{0}/CHANGELOG.md).' -f $Scope.ModuleRelativePath
    if ($lines.Count -lt 5 -or $lines[0] -cne '# Changelog' -or
        $lines[1] -cne '' -or $lines[2] -cne $expectedLink -or $lines[3] -cne '') {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $changelogPath `
                    -Code 'avm.bicep.changelog-header' -Line 1 `
                    -Message "Start CHANGELOG.md with '# Changelog', a blank line, the canonical $($Scope.ModuleRelativePath) link, and a blank line."))
    }

    $versions = [System.Collections.Generic.List[object]]::new()
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        if ($lines[$lineIndex] -cnotmatch '^##\s') {
            continue
        }
        $heading = [regex]::Match($lines[$lineIndex], '^## ([0-9]+\.[0-9]+\.[0-9]+)\s*$')
        $parsed = $null
        if (-not $heading.Success -or -not [version]::TryParse($heading.Groups[1].Value, [ref]$parsed)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $changelogPath `
                        -Code 'avm.bicep.changelog-version' -Line ($lineIndex + 1) `
                        -Message 'Changelog section headings must be semantic versions (## major.minor.patch).'))
            continue
        }
        $versions.Add([pscustomobject]@{
                Index   = $lineIndex
                Version = $parsed
            })
    }

    if ($versions.Count -eq 0) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $changelogPath `
                    -Code 'avm.bicep.changelog-versions-missing' -Line 1 `
                    -Message 'CHANGELOG.md requires at least one version section.'))
        return $issues.ToArray()
    }

    for ($index = 0; $index -lt $versions.Count; $index++) {
        $entry = $versions[$index]
        if ($index -gt 0 -and $entry.Version -ge $versions[$index - 1].Version) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $changelogPath `
                        -Code 'avm.bicep.changelog-order' -Line ($entry.Index + 1) `
                        -Message 'Changelog versions must be unique and sorted newest first.'))
        }

        $next = if ($index + 1 -lt $versions.Count) { $versions[$index + 1].Index } else { $lines.Count }
        $sections = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[int]]]::new(
            [System.StringComparer]::Ordinal)
        foreach ($name in @('Changes', 'Breaking Changes')) {
            $sections[$name] = [System.Collections.Generic.List[int]]::new()
        }
        for ($sectionIndex = $entry.Index + 1; $sectionIndex -lt $next; $sectionIndex++) {
            foreach ($name in @('Changes', 'Breaking Changes')) {
                if ($lines[$sectionIndex] -ceq "### $name") {
                    $sections[$name].Add($sectionIndex)
                }
            }
        }
        foreach ($name in @('Changes', 'Breaking Changes')) {
            if ($sections[$name].Count -ne 1) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $changelogPath `
                            -Code 'avm.bicep.changelog-section' -Line ($entry.Index + 1) `
                            -Message "Version $($entry.Version) requires exactly one '### $name' section."))
                continue
            }

            $start = $sections[$name][0]
            $end = $next
            for ($candidate = $start + 1; $candidate -lt $next; $candidate++) {
                if ($lines[$candidate] -cmatch '^###\s') {
                    $end = $candidate
                    break
                }
            }
            $hasContent = $false
            for ($candidate = $start + 1; $candidate -lt $end; $candidate++) {
                if (-not [string]::IsNullOrWhiteSpace($lines[$candidate])) {
                    $hasContent = $true
                    break
                }
            }
            if (-not $hasContent) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $changelogPath `
                            -Code 'avm.bicep.changelog-section-empty' -Line ($start + 1) `
                            -Message "Version $($entry.Version) needs content in its '$name' section."))
            }
        }
        if ($sections['Changes'].Count -eq 1 -and $sections['Breaking Changes'].Count -eq 1 -and
            $sections['Changes'][0] -gt $sections['Breaking Changes'][0]) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $changelogPath `
                        -Code 'avm.bicep.changelog-section-order' -Line ($entry.Index + 1) `
                        -Message "Version $($entry.Version) must list Changes before Breaking Changes."))
        }
    }

    return $issues.ToArray()
}
