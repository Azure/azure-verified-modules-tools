function Initialize-AvmBicepReleaseMatrix {
    <#
    .SYNOPSIS
        Build a guarded top-level Bicep release matrix.

    .DESCRIPTION
        Verifies the exact upstream registry main checkout and push remote before
        selecting release roots with publishable changes since BaseCommit.
        Manual mode defaults to the target's first parent when no base is
        provided. Tag creation preserves independent child and parent baselines.

    .PARAMETER Root
        Existing filesystem repository root.

    .PARAMETER EventName
        Release event type: push or workflow_dispatch.

    .PARAMETER TargetCommit
        Full SHA-1 release target checked out at Root.

    .PARAMETER BaseCommit
        Full SHA-1 comparison commit. Required for push; optional for a manual
        retry of a release covering more than one commit.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery version check for source or offline callers.

    .OUTPUTS
        PSCustomObject with BaseCommit and an Include array of top-level module paths.

    .EXAMPLE
        PS> Initialize-AvmBicepReleaseMatrix -Root $repo -EventName workflow_dispatch -TargetCommit $sha
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory)] [ValidateSet('workflow_dispatch', 'push')] [string] $EventName,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit,
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $parameters = @{} + $PSBoundParameters
    $null = $parameters.Remove('SkipModuleVersionCheck')
    $matrix = Initialize-AvmBicepReleaseMatrixInternal @parameters
    return [pscustomobject]@{
        BaseCommit = $matrix.baseCommit
        Include    = @($matrix.include | ForEach-Object { [pscustomobject]@{ ModulePath = $_.modulePath } })
    }
}
