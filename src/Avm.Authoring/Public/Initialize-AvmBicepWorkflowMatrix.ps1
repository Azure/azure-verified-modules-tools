function Initialize-AvmBicepWorkflowMatrix {
    <#
    .SYNOPSIS
        Discover a checked-out Bicep workflow matrix for a push, pull request, or manual run.

    .DESCRIPTION
        Validates the exact checked-out target commit before building a module
        matrix. Pull request discovery requires the tested merge commit to have
        exactly two parents and verifies the supplied pull request head is the
        second parent. Push discovery uses the supplied base when available and
        otherwise selects every current module for static-only preview. Manual
        dispatch uses explicit module paths.

    .PARAMETER Root
        Existing filesystem repository root.

    .PARAMETER EventName
        GitHub event type: push, pull_request, or workflow_dispatch.

    .PARAMETER TargetCommit
        Full SHA-1 commit checked out at Root.

    .PARAMETER BaseCommit
        Full SHA-1 comparison commit for push discovery.

    .PARAMETER PullRequestHeadCommit
        Full SHA-1 pull request head that must be the tested merge's second parent.

    .PARAMETER ModulePaths
        Comma-separated manual module selection for workflow_dispatch.

    .PARAMETER CreateReleaseTag
        Indicates a release-tag workflow request.

    .PARAMETER PublishOnly
        Indicates tag-only publication, which requires CreateReleaseTag.

    .PARAMETER StaticValidation
        Enables static validation in the returned workflow input.

    .PARAMETER DeploymentValidation
        Enables deployment validation in the returned workflow input.

    .PARAMETER RemoveDeployment
        Requests deployment cleanup in the returned workflow input.

    .PARAMETER CustomLocation
        Optional deployment location in the returned workflow input.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery version check for source or offline callers.

    .OUTPUTS
        PSCustomObject containing commit data, selection flags, a structured
            ModuleMatrix, and structured WorkflowInput settings.

    .EXAMPLE
        PS> Initialize-AvmBicepWorkflowMatrix -Root $repo -EventName workflow_dispatch -TargetCommit $sha -ModulePaths 'avm/res/storage/storage-account'
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAlignAssignmentStatement', '',
        Justification = 'Output property names are part of the public matrix contract.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory)] [ValidateSet('push', 'pull_request', 'workflow_dispatch')] [string] $EventName,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit,
        [string] $PullRequestHeadCommit,
        [string] $ModulePaths,
        [bool] $CreateReleaseTag = $false,
        [bool] $PublishOnly = $false,
        [bool] $StaticValidation = $true,
        [bool] $DeploymentValidation = $true,
        [bool] $RemoveDeployment = $true,
        [string] $CustomLocation,
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $parameters = @{} + $PSBoundParameters
    $null = $parameters.Remove('SkipModuleVersionCheck')
    $result = Initialize-AvmBicepWorkflowMatrixInternal @parameters
    $legacyMatrix = $result.moduleMatrix | ConvertFrom-Json
    $matrix = [pscustomobject]@{
        Include = @($legacyMatrix.include | ForEach-Object {
                [pscustomobject]@{
                    ModulePath = $_.modulePath
                    TestFiles = @($_.moduleTestFilePaths | ConvertFrom-Json)
                    PolicyTestFiles = @($_.psRuleModuleTestFilePaths | ConvertFrom-Json)
                }
            })
    }
    return [pscustomobject]@{
        BaseCommit = $result.baseCommit
        TargetCommit = $result.targetCommit
        HasModules = $result.hasModules -ceq 'true'
        IncludeAllVersionedModules = $result.includeAllVersionedModules -ceq 'true'
        ModuleMatrix = $matrix
        WorkflowInput = $result.workflowInput | ConvertFrom-Json
    }
}
