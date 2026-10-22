function Get-AvmBicepWorkflowModuleMatrix {
    <#
    .SYNOPSIS
        Build a deterministic Bicep module workflow matrix.

    .DESCRIPTION
        Selects existing top-level AVM Bicep modules from either explicit manual
        paths or changed repository paths. Matrix entries include static, E2E,
        and PSRule policy metadata from Get-AvmBicepWorkflowTestFiles. README
        changes are ignored, and callers can also exclude metadata-only changes.
        Paths are validated as literal repository-relative paths.

    .PARAMETER Root
        Existing filesystem repository root.

    .PARAMETER ModulePaths
        Comma-separated manually selected top-level Bicep module paths.

    .PARAMETER ChangedFiles
        Changed repository-relative paths from which module roots are inferred.

    .PARAMETER ExcludeMetadataChanges
        Ignore metadata.json changes while processing ChangedFiles.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery version check for source or offline callers.

    .OUTPUTS
        PSCustomObject with an Include array. Each entry has ModulePath, TestFiles,
            and PolicyTestFiles properties.

    .EXAMPLE
        PS> Get-AvmBicepWorkflowModuleMatrix -Root $repo -ModulePaths 'avm/res/storage/storage-account'

    .EXAMPLE
        PS> Get-AvmBicepWorkflowModuleMatrix -Root $repo -ChangedFiles $changed -ExcludeMetadataChanges
    #>
    [CmdletBinding(DefaultParameterSetName = 'Changed')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAlignAssignmentStatement', '',
        Justification = 'Output property names are part of the public matrix contract.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory, ParameterSetName = 'Requested')] [ValidateNotNullOrEmpty()] [string] $ModulePaths,
        [Parameter(Mandatory, ParameterSetName = 'Changed')] [AllowEmptyCollection()] [string[]] $ChangedFiles,
        [switch] $ExcludeMetadataChanges,
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $parameters = @{} + $PSBoundParameters
    $null = $parameters.Remove('SkipModuleVersionCheck')
    $matrix = Get-AvmBicepWorkflowModuleMatrixInternal @parameters
    $include = @($matrix.include | ForEach-Object {
            [pscustomobject]@{
                ModulePath = $_.modulePath
                TestFiles = @($_.moduleTestFilePaths | ConvertFrom-Json)
                PolicyTestFiles = @($_.psRuleModuleTestFilePaths | ConvertFrom-Json)
            }
        })
    return [pscustomobject]@{ Include = $include }
}
