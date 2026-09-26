function Initialize-AvmModule {
    <#
    .SYNOPSIS
        Initialize a Bicep or Terraform module locally.
    .DESCRIPTION
        With -Proposed, creates only metadata.json for an unpublished Bicep
        module, including a missing module directory. Existing metadata is
        validated and left unchanged. Missing required metadata is prompted for
        only in an interactive terminal. Terraform initialization also creates
        only metadata.json and its containing directory; add Terraform source
        manually afterward. Full Bicep source scaffolding is not yet available.
        This command never creates a remote repository.
    .PARAMETER Path
        Module directory to initialize.
    .PARAMETER Ecosystem
        Bicep or Terraform.
    .PARAMETER ModuleType
        Resource, pattern, or utility.
    .PARAMETER InputObject
        Optional complete or partial metadata values.
    .PARAMETER ChildModule
        Initialize a child module without root ownership fields.
    .PARAMETER Proposed
        Create only metadata.json for a proposed Bicep module.
    .PARAMETER SkipModuleVersionCheck
        Skip the installed-module version check for a trusted checkout.
    .EXAMPLE
        avm init -Ecosystem bicep -ModuleType resource -Path ./avm/res/storage/storage-account -Proposed
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = $PWD.Path,

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [System.Collections.IDictionary] $InputObject = @{},

        [switch] $ChildModule,

        [switch] $Proposed,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Proposed -and $Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new('-Proposed is only supported for Bicep modules.')
    }
    if ($Ecosystem -eq 'bicep' -and -not $Proposed) {
        throw [AvmNotSupportedException]::new('Full Bicep scaffolding is not yet available. Use -Proposed for metadata-only initialization.')
    }

    $parameters = @{
        Path                   = $Path
        Ecosystem              = $Ecosystem
        ModuleType             = $ModuleType
        InputObject            = $InputObject
        ChildModule            = $ChildModule
        CreateDirectory        = $Ecosystem -eq 'terraform'
        SkipModuleVersionCheck = $SkipModuleVersionCheck
        WhatIf                 = $WhatIfPreference
    }
    if ($PSBoundParameters.ContainsKey('Confirm')) {
        $parameters.Confirm = $PSBoundParameters['Confirm']
    }
    return Initialize-AvmModuleMetadata @parameters
}
