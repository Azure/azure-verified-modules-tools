function Get-AvmBicepPendingReleasePlan {
    <#
    .SYNOPSIS
        Discover versioned Bicep modules awaiting release tags.

    .DESCRIPTION
        Inspects complete Git history and the upstream tag state to identify
        changed versioned child and parent modules beneath a supplied module
        root. Each returned plan entry preserves its independent baseline, so
        child releases are evaluated independently of their parent module.
        This command reads Git state only and creates no tags.

    .PARAMETER Root
        Existing filesystem repository root.

    .PARAMETER ModulePath
        Exact repository-relative module root beneath which to discover releases.

    .PARAMETER TargetCommit
        Full SHA-1 release target commit.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery version check for source or offline callers.

    .OUTPUTS
        PSCustomObject records with ModulePath, BaseCommit, and InitialRelease.

    .EXAMPLE
        PS> Get-AvmBicepPendingReleasePlan -Root $repo -ModulePath avm -TargetCommit $sha
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $parameters = @{} + $PSBoundParameters
    $null = $parameters.Remove('SkipModuleVersionCheck')
    return Get-AvmBicepWorkflowPendingReleasePlanInternal @parameters
}
