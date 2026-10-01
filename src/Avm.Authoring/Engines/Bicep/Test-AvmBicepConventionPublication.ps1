function Test-AvmBicepConventionPublication {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [object[]] $Scopes
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $versioned = [System.Collections.Generic.List[object]]::new()
    foreach ($scope in $Scopes) {
        $versionPath = Join-Path $scope.Path 'version.json'
        try {
            $files = @(Get-ChildItem -LiteralPath $scope.Path -Force -ErrorAction Stop |
                    Where-Object { $_.Name -ieq 'version.json' })
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException],
        [System.Management.Automation.ActionPreferenceStopException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $versionPath `
                        -Code 'avm.bicep.publication-version-file' `
                        -Message "Cannot inspect version.json for publication checks: $($_.Exception.Message)"))
            continue
        }
        if ($files.Count -eq 0) {
            continue
        }
        if ($files.Count -ne 1 -or $files[0].Name -cne 'version.json' -or
            $files[0].PSIsContainer -or
            ($files[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $versionPath `
                        -Code 'avm.bicep.publication-version-file' `
                        -Message 'Publication checks require a regular version.json with exact casing.'))
            continue
        }
        try {
            $data = [System.IO.File]::ReadAllText($versionPath) |
                ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException],
        [System.Management.Automation.RuntimeException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $versionPath `
                        -Code 'avm.bicep.publication-version-file' `
                        -Message "Cannot read version.json for publication checks: $($_.Exception.Message)"))
            continue
        }
        $parsed = $null
        if ($data -isnot [System.Collections.IDictionary] -or
            $data['version'] -isnot [string] -or
            $data['version'] -cnotmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z' -or
            -not [version]::TryParse("$($data['version']).0", [ref]$parsed)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $versionPath `
                        -Code 'avm.bicep.publication-version-file' `
                        -Message 'Publication checks require a canonical major.minor version.json.'))
            continue
        }
        $versioned.Add([pscustomobject]@{ Scope = $scope; Version = $data['version'] })
    }
    if ($versioned.Count -eq 0) {
        return $issues.ToArray()
    }
    if ($env:AVM_OFFLINE -eq '1') {
        foreach ($entry in $versioned) {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot `
                        -Path (Join-Path $entry.Scope.Path 'version.json') `
                        -Code 'avm.bicep.published-tags-offline' `
                        -Message 'AVM_OFFLINE=1: cannot verify the full published MCR tag set or the next target version.'))
        }
        return $issues.ToArray()
    }

    try {
        $gitState = Get-AvmBicepPublicationGitState -RepositoryRoot $RepositoryRoot
    }
    catch [AvmConfigurationException], [AvmProcessException], [System.TimeoutException] {
        $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $RepositoryRoot `
                    -Code 'avm.bicep.publication-git-state' `
                    -Message "Cannot check upstream publication history: $($_.Exception.Message)"))
        return $issues.ToArray()
    }

    $targets = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::Ordinal)
    foreach ($entry in $versioned) {
        $scope = $entry.Scope
        $changelogPath = Join-Path $scope.Path 'CHANGELOG.md'
        try {
            $target = Get-AvmBicepPublicationTargetVersion -Scope $scope `
                -Version $entry.Version -GitState $gitState
            $targets[$scope.ModuleRelativePath] = $target
        }
        catch [AvmConfigurationException], [AvmProcessException], [System.TimeoutException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot `
                        -Path (Join-Path $scope.Path 'version.json') `
                        -Code 'avm.bicep.target-version-unavailable' `
                        -Message "Cannot determine the next version of '$($scope.ModuleRelativePath)': $($_.Exception.Message)"))
            continue
        }
        try {
            $published = Get-AvmBicepMcrTagList -ModulePath $scope.ModuleRelativePath
        }
        catch [AvmConfigurationException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $changelogPath `
                        -Code 'avm.bicep.published-tags-unavailable' `
                        -Message $_.Exception.Message))
            continue
        }

        try {
            $changelogs = @(Get-ChildItem -LiteralPath $scope.Path -Force -ErrorAction Stop |
                    Where-Object { $_.Name -ieq 'CHANGELOG.md' })
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException],
        [System.Management.Automation.ActionPreferenceStopException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $changelogPath `
                        -Code 'avm.bicep.publication-changelog' `
                        -Message "Cannot inspect CHANGELOG.md for publication checks: $($_.Exception.Message)"))
            continue
        }
        if ($changelogs.Count -ne 1 -or $changelogs[0].Name -cne 'CHANGELOG.md' -or
            $changelogs[0].PSIsContainer -or
            ($changelogs[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $changelogPath `
                        -Code 'avm.bicep.publication-changelog' `
                        -Message 'Publication checks require a regular CHANGELOG.md with exact casing.'))
            continue
        }
        try {
            $lines = [System.IO.File]::ReadAllLines($changelogPath)
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $changelogPath `
                        -Code 'avm.bicep.publication-changelog' `
                        -Message "Cannot read CHANGELOG.md for publication checks: $($_.Exception.Message)"))
            continue
        }

        $hasTarget = $false
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -cnotmatch '^##\s') {
                continue
            }
            $heading = [regex]::Match($lines[$index], '^## (?<version>[0-9]+\.[0-9]+\.[0-9]+)\s*\z')
            if (-not $heading.Success) {
                continue
            }
            $version = $heading.Groups['version'].Value
            if ($version -ceq $target.TargetVersion) {
                $hasTarget = $true
            }
            elseif (-not $published.Tags.Contains($version)) {
                $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $changelogPath `
                            -Line ($index + 1) -Code 'avm.bicep.changelog-unpublished-version' `
                            -Message "Changelog version '$version' is neither in MCR's published tags for '$($scope.ModuleRelativePath)' nor the next target '$($target.TargetVersion)'."))
            }
        }
        if ($target.ShouldPublish -and -not $hasTarget) {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $changelogPath `
                        -Code 'avm.bicep.changelog-target-version' `
                        -Message "A publishable change to '$($scope.ModuleRelativePath)' requires a '## $($target.TargetVersion)' section."))
        }
    }

    foreach ($entry in $versioned) {
        $child = $entry.Scope
        if ($child.IsTopLevel -or -not $targets.ContainsKey($child.ModuleRelativePath)) {
            continue
        }
        $childTarget = $targets[$child.ModuleRelativePath]
        if (-not $childTarget.VersionChanged -or $null -eq $childTarget.PreviousVersion -or
            $childTarget.TargetVersion -ceq '0.1.0' -or
            -not $childTarget.TargetVersion.EndsWith('.0', [System.StringComparison]::Ordinal)) {
            continue
        }
        $ancestor = $child.ModuleRelativePath
        while ($ancestor.LastIndexOf('/') -gt 0) {
            $ancestor = $ancestor.Substring(0, $ancestor.LastIndexOf('/'))
            if ($ancestor -ceq "avm/$($child.ModuleType)") {
                break
            }
            $ancestorPath = Join-Path $RepositoryRoot $ancestor
            $versionPath = Join-Path $ancestorPath 'version.json'
            if (-not (Test-Path -LiteralPath $versionPath)) {
                continue
            }
            if (-not $targets.ContainsKey($ancestor)) {
                $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $versionPath `
                            -Code 'avm.bicep.parent-version-uninspectable' `
                            -Message "Cannot verify versioned ancestor '$ancestor' after '$($child.ModuleRelativePath)' changed version."))
                continue
            }
            $parent = $targets[$ancestor]
            $increased = $true
            if ($null -ne $parent.PreviousVersion) {
                $currentVersion = [version]::Parse("$($parent.TargetVersion)")
                $previousVersion = [version]::Parse("$($parent.PreviousVersion).0")
                $increased = $currentVersion -gt $previousVersion
            }
            if (-not $parent.VersionChanged -or -not $increased -or
                -not $parent.TargetVersion.EndsWith('.0', [System.StringComparison]::Ordinal)) {
                $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $versionPath `
                            -Code 'avm.bicep.parent-version-not-increased' `
                            -Message "Versioned ancestor '$ancestor' must increment its major.minor and reset the target patch to .0 after child '$($child.ModuleRelativePath)' changes to '$($childTarget.TargetVersion)'."))
            }
        }
    }
    return $issues.ToArray()
}
