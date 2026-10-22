function Get-AvmBicepWorkflowTestFiles {
    <#
    .SYNOPSIS
        Discover native Bicep test files and policy candidates for one module.

    .DESCRIPTION
        Resolves an exact repository-relative Bicep module path, discovers its
        main.test.bicep files, and returns compact JSON arrays for workflow
        matrices. Each test record includes its module-relative path, display
        name, and .e2eignore state. The policy array contains the tests whose
        paths match PsRuleFilterRegex.

    .PARAMETER Root
        Existing filesystem repository root that contains the module.

    .PARAMETER ModulePath
        Exact repository-relative module path using forward slashes.

    .PARAMETER PsRuleFilterRegex
        Regular expression that selects policy test files. It defaults to
        defaults and waf-aligned test paths.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery version check for source or offline callers.

    .OUTPUTS
        PSCustomObject with TestFiles and PolicyTestFiles arrays.

    .EXAMPLE
        PS> Get-AvmBicepWorkflowTestFiles -Root $repo -ModulePath 'avm/res/storage/storage-account'
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The command discovers the complete test-file collection.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAlignAssignmentStatement', '',
        Justification = 'Output property names are part of the public result contract.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ModulePath,
        [string] $PsRuleFilterRegex = '(defaults|waf-aligned)',
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $parameters = @{} + $PSBoundParameters
    $null = $parameters.Remove('SkipModuleVersionCheck')
    $files = Get-AvmBicepWorkflowTestFilesInternal @parameters
    return [pscustomobject]@{
        TestFiles = @($files.moduleTestFilePaths | ConvertFrom-Json)
        PolicyTestFiles = @($files.psRuleModuleTestFilePaths | ConvertFrom-Json)
    }
}
