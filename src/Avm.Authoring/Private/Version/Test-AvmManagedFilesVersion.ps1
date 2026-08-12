function Test-AvmManagedFilesVersion {
    <#
    .SYNOPSIS
        Classify the drift between the managed-files release a repository is
        pinned to and the latest published release.

    .DESCRIPTION
        Returns the classification rather than acting on it so each caller can
        apply its own policy: pre-commit warns on a minor or patch and refuses
        to sync on a major, pr-check fails on a major, and repository sync
        gates a bump on open pull request activity.

        Statuses:
          upToDate - the pin is at or ahead of the latest release.
          patch    - a newer patch release exists.
          minor    - a newer minor release exists.
          major    - a newer major release exists; adoption is mandatory.
          unpinned - the repository has no pin yet.
          unknown  - the latest release could not be determined.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [semver] $PinnedVersion,

        [AllowNull()]
        [semver] $LatestVersion
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $status = if ($null -eq $PinnedVersion) {
        'unpinned'
    }
    elseif ($null -eq $LatestVersion) {
        'unknown'
    }
    elseif ($LatestVersion -le $PinnedVersion) {
        'upToDate'
    }
    elseif ($LatestVersion.Major -gt $PinnedVersion.Major) {
        'major'
    }
    elseif ($LatestVersion.Minor -gt $PinnedVersion.Minor) {
        'minor'
    }
    else {
        'patch'
    }

    return [pscustomobject][ordered]@{
        Status        = $status
        PinnedVersion = $PinnedVersion
        LatestVersion = $LatestVersion
        IsBehind      = $status -in @('patch', 'minor', 'major')
        IsMajorBehind = $status -eq 'major'
    }
}
