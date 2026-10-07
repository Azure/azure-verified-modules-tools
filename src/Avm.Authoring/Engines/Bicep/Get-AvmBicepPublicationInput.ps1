function Get-AvmBicepPublicationInput {
    <#
    .SYNOPSIS
        Gather version.json, git history and published MCR tags for the publication convention rule.

    .DESCRIPTION
        Performs all filesystem discovery, git and network work up front so the packaged
        convention suite only evaluates prepared data. Problems that prevent a check are
        returned as convention issues rather than thrown.

    .OUTPUTS
        pscustomobject with Issues, Entries (Scope, Version, Target, Published) and
        Targets keyed by module path. Target or Published is null when unavailable.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Scopes
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()
    $targets = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $result = {
        [pscustomobject]@{ Issues = $issues.ToArray(); Entries = $entries.ToArray(); Targets = $targets }
    }

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
        $entries.Add([pscustomobject]@{ Scope = $scope; Version = $data['version']; Target = $null; Published = $null })
    }
    if ($entries.Count -eq 0) {
        return (& $result)
    }
    if ($env:AVM_OFFLINE -eq '1') {
        foreach ($entry in $entries) {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot `
                        -Path (Join-Path $entry.Scope.Path 'version.json') `
                        -Code 'avm.bicep.published-tags-offline' `
                        -Message 'AVM_OFFLINE=1: cannot verify the full published MCR tag set or the next target version.'))
        }
        $entries.Clear()
        return (& $result)
    }

    try {
        $gitState = Get-AvmBicepPublicationGitState -RepositoryRoot $RepositoryRoot
    }
    catch [AvmConfigurationException], [AvmProcessException], [System.TimeoutException] {
        $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $RepositoryRoot `
                    -Code 'avm.bicep.publication-git-state' `
                    -Message "Cannot check upstream publication history: $($_.Exception.Message)"))
        $entries.Clear()
        return (& $result)
    }

    foreach ($entry in $entries) {
        $scope = $entry.Scope
        try {
            $entry.Target = Get-AvmBicepPublicationTargetVersion -Scope $scope `
                -Version $entry.Version -GitState $gitState
            $targets[$scope.ModuleRelativePath] = $entry.Target
        }
        catch [AvmConfigurationException], [AvmProcessException], [System.TimeoutException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot `
                        -Path (Join-Path $scope.Path 'version.json') `
                        -Code 'avm.bicep.target-version-unavailable' `
                        -Message "Cannot determine the next version of '$($scope.ModuleRelativePath)': $($_.Exception.Message)"))
            continue
        }
        try {
            $entry.Published = Get-AvmBicepMcrTagList -ModulePath $scope.ModuleRelativePath
        }
        catch [AvmConfigurationException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot `
                        -Path (Join-Path $scope.Path 'CHANGELOG.md') `
                        -Code 'avm.bicep.published-tags-unavailable' `
                        -Message $_.Exception.Message))
        }
    }
    return (& $result)
}
