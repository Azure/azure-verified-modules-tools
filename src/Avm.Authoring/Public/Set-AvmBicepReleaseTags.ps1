function Set-AvmBicepReleaseTags {
    <#
    .SYNOPSIS
        Create guarded Bicep module release tags from a checked-out target.

    .DESCRIPTION
        Validates the upstream registry main checkout, source commit, remote,
        and unchanged module files before planning release tags. It preserves
        independent child and parent baselines, plans children before parents,
        and reuses tags already pointing to the target. When RequireChangelog
        is set, every exact planned target version is validated before any tag
        is created. Failed or timed-out pushes are reconciled by reading remote
        state and are never blindly retried.

    .PARAMETER Root
        Existing filesystem repository root.

    .PARAMETER ModulePath
        Exact repository-relative top-level module path.

    .PARAMETER TargetCommit
        Full SHA-1 commit to tag.

    .PARAMETER BaseCommit
        Optional full SHA-1 baseline for push discovery.

    .PARAMETER Force
        Include the top-level module even when no publishable changes are found.

    .PARAMETER IncludeAllVersionedModules
        Preview-only fallback that includes every versioned module below ModulePath.

    .PARAMETER PendingRelease
        Discover each child and parent baseline from existing release tags.

    .PARAMETER RequireChangelog
        Require each planned target tag version to have one complete changelog section
        before any tag mutation. It is off by default for compatibility.

    .PARAMETER WhatIf
        Show tags that would be created without mutating local or remote Git state.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery version check for source or offline callers.

    .OUTPUTS
        PSCustomObject records with Module, Tag, Commit, Reused, and Created.

    .EXAMPLE
        PS> Set-AvmBicepReleaseTags -Root $repo -ModulePath 'avm/res/storage/storage-account' -TargetCommit $sha -PendingRelease -RequireChangelog -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'The implementation owns tag mutation and receives the caller WhatIf preference.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The command plans and returns the complete release-tag collection.')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit,
        [switch] $Force,
        [switch] $IncludeAllVersionedModules,
        [switch] $PendingRelease,
        [switch] $RequireChangelog,
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $parameters = @{} + $PSBoundParameters
    $null = $parameters.Remove('SkipModuleVersionCheck')
    return Set-AvmBicepReleaseTagsInternal @parameters
}
