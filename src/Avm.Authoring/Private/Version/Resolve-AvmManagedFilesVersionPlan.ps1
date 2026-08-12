function Resolve-AvmManagedFilesVersionPlan {
    <#
    .SYNOPSIS
        Decide which managed-files ref to sync from, and whether the repository
        version pin should be stamped afterwards.

    .DESCRIPTION
        Compares the repository's '.avm/managed-files-version.json' pin against
        the newest semver tag published by the managed-files repository and
        returns a plan describing the ref to fetch, the drift status, and
        whether the caller should write the pin back.

        Version handling is bypassed when a local managed-files path is in use,
        when the caller opted out, or when the ref was explicitly overridden by
        a parameter, an environment variable, or '.avm/managed-files.json'; in
        those cases the caller has deliberately chosen a source and the pin has
        nothing to say about it.

    .OUTPUTS
        Hashtable with Ref, Status, PinnedVersion, LatestVersion,
        TargetVersion, ShouldStamp and Message.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a plan hashtable; the caller performs any write.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Settings,

        [AllowEmptyString()]
        [string] $GitPath = '',

        [switch] $Upgrade,

        [switch] $SkipVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $plan = @{
        Ref           = if ($Settings.ContainsKey('ManagedFilesRef')) { $Settings.ManagedFilesRef } else { 'main' }
        Status        = 'skipped'
        PinnedVersion = $null
        LatestVersion = $null
        TargetVersion = $null
        ShouldStamp   = $false
        Message       = $null
    }

    if ($SkipVersionCheck) { return $plan }
    if ($Settings.ContainsKey('ManagedFilesLocalPath') -and $Settings.ManagedFilesLocalPath) { return $plan }

    $refSource = if ($Settings.ContainsKey('ManagedFilesRefSource')) { [string]$Settings.ManagedFilesRefSource } else { 'default' }
    if ($refSource -in @('explicit', 'environment', 'file')) {
        $plan.Status = 'overridden'
        if ($Upgrade) {
            $plan.Message = "managed-files ref is pinned to '$($plan.Ref)' by an explicit override; -Upgrade has no effect."
        }
        return $plan
    }

    $pin = if ($Settings.ContainsKey('ManagedFilesVersionPin')) { $Settings.ManagedFilesVersionPin } else { $null }
    $pinnedVersion = if ($pin) { [semver]$pin.Version } else { $null }
    $plan.PinnedVersion = $pinnedVersion

    $latestVersion = $null
    $lookupError = $null
    try {
        $latestVersion = Get-AvmLatestManagedFilesVersion -Repo $Settings.ManagedFilesRepo -GitPath $GitPath
    }
    catch [AvmManagedFilesLookupException] {
        $lookupError = $_.Exception.Message
    }
    $plan.LatestVersion = $latestVersion

    $check = Test-AvmManagedFilesVersion -PinnedVersion $pinnedVersion -LatestVersion $latestVersion
    $plan.Status = $check.Status
    $lookupDetail = if ($lookupError) { " $lookupError" } else { '' }

    if ($Upgrade -and -not $latestVersion) {
        throw [AvmManagedFilesVersionException]::new(
            "Cannot upgrade managed files: the latest version of '$($Settings.ManagedFilesRepo)' could not be determined.$lookupDetail")
    }

    switch ($check.Status) {
        'unpinned' {
            if ($latestVersion) {
                $plan.Ref = 'v{0}' -f $latestVersion
                $plan.TargetVersion = $latestVersion
                $plan.ShouldStamp = $true
            }
            else {
                $plan.Ref = 'main'
                $plan.Message = "Could not determine the latest managed-files version and this repository has no version pin; continuing from 'main'.$lookupDetail"
            }
        }
        'unknown' {
            $plan.Ref = 'v{0}' -f $pinnedVersion
            $plan.Message = "Could not determine the latest managed-files version; continuing with the pinned version $pinnedVersion.$lookupDetail"
        }
        'upToDate' {
            $plan.Ref = 'v{0}' -f $pinnedVersion
        }
        default {
            if ($Upgrade) {
                $plan.Ref = 'v{0}' -f $latestVersion
                $plan.TargetVersion = $latestVersion
                $plan.ShouldStamp = $true
            }
            else {
                $plan.Ref = 'v{0}' -f $pinnedVersion
                $plan.Message = if ($check.Status -eq 'major') {
                    "Managed files $latestVersion is a major release ahead of the pinned version $pinnedVersion and must be adopted. Run 'avm pre-commit -Upgrade' to update."
                }
                else {
                    "Managed files $latestVersion is available; this repository is pinned to $pinnedVersion. Run 'avm pre-commit -Upgrade' to update."
                }
            }
        }
    }

    return $plan
}
