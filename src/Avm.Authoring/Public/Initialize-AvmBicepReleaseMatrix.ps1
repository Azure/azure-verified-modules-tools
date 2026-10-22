function Initialize-AvmBicepReleaseMatrix {
    <#
    .SYNOPSIS
        Build a guarded top-level Bicep release matrix.

    .DESCRIPTION
        Verifies the exact upstream registry main checkout and push remote before
        selecting release roots. Push mode discovers changed publishable modules
        from BaseCommit. Manual mode discovers pending releases from complete
        tag history. The result contains top-level module roots only; tag
        creation later preserves independent child and parent baselines.

    .PARAMETER Root
        Existing filesystem repository root.

    .PARAMETER EventName
        Release event type: push or workflow_dispatch.

    .PARAMETER TargetCommit
        Full SHA-1 release target checked out at Root.

    .PARAMETER BaseCommit
        Full SHA-1 push comparison commit.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery version check for source or offline callers.

    .OUTPUTS
        PSCustomObject with an Include array of top-level module paths.

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
        Include = @($matrix.include | ForEach-Object { [pscustomobject]@{ ModulePath = $_.modulePath } })
    }
}
