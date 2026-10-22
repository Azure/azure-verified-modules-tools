. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-AvmWorkflowRemoteTags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Pattern
    )

    return Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepWorkflowRemoteTags -Parameters $PSBoundParameters
}

function Get-AvmWorkflowPublishableChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit,
        [switch] $InitialRelease,
        [switch] $ExactModule
    )

    return Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepWorkflowPublishableChangesInternal -Parameters $PSBoundParameters
}

function Get-AvmWorkflowPendingReleasePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TargetCommit
    )

    return Get-AvmBicepPendingReleasePlan @PSBoundParameters
}

function Assert-AvmWorkflowReleaseContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $TargetCommit
    )

    return Invoke-AvmWorkflowPackagePrivate -Name Assert-AvmBicepWorkflowReleaseContext -Parameters $PSBoundParameters
}

function Initialize-AvmWorkflowReleaseMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [ValidateSet('workflow_dispatch', 'push')] [string] $EventName,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit
    )

    return Invoke-AvmWorkflowPackagePrivate -Name Initialize-AvmBicepReleaseMatrixInternal -Parameters $PSBoundParameters
}

function Assert-AvmWorkflowReleaseChangelog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $Version
    )

    return Invoke-AvmWorkflowPackagePrivate -Name Assert-AvmBicepWorkflowReleaseChangelog -Parameters $PSBoundParameters
}

function Set-AvmWorkflowReleaseTags {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit,
        [switch] $Force,
        [switch] $IncludeAllVersionedModules,
        [switch] $PendingRelease,
        [switch] $RequireChangelog
    )

    return Set-AvmBicepReleaseTags @PSBoundParameters
}
