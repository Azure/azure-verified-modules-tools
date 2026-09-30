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
        manually afterward. Full Bicep initialization creates local source,
        version, changelog, and root e2e test files without overwriting
        existing files. For nested child paths, it also initializes missing
        ancestors. This command never creates a remote repository.
    .PARAMETER Path
        Module directory to initialize.
    .PARAMETER Ecosystem
        Bicep or Terraform.
    .PARAMETER ModuleType
        Resource, pattern, or utility.
    .PARAMETER InputObject
        Optional complete or partial metadata values for the target module.
    .PARAMETER AncestorInputObject
        Metadata for missing ancestors during full Bicep child initialization,
        keyed by exact root-relative paths: '.' for the root and 'child/name'
        for a nested parent. Existing ancestors ignore their supplied values.
        Interactive users may omit entries and answer the metadata prompts.
    .PARAMETER ChildModule
        Initialize a child module without root ownership fields.
    .PARAMETER Proposed
        Create only metadata.json for a proposed Bicep module.
    .PARAMETER SkipModuleVersionCheck
        Skip the installed-module version check for a trusted checkout.
    .EXAMPLE
        avm init -Ecosystem bicep -ModuleType resource -Path ./avm/res/storage/storage-account -Proposed
    .EXAMPLE
        avm init -Ecosystem bicep -ModuleType resource -Path ./avm/res/storage/storage-account/blob-service/container -ChildModule -InputObject $childMetadata -AncestorInputObject @{ '.' = $rootMetadata; 'blob-service' = $parentMetadata }
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

        [System.Collections.IDictionary] $AncestorInputObject = @{},

        [switch] $ChildModule,

        [switch] $Proposed,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Proposed -and $Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new('-Proposed is only supported for Bicep modules.')
    }
    if (($Proposed -or $Ecosystem -ne 'bicep') -and $AncestorInputObject.Count -gt 0) {
        throw [System.ArgumentException]::new('-AncestorInputObject is only supported for full Bicep child initialization.')
    }
    if ($Ecosystem -eq 'bicep' -and -not $Proposed) {
        $initialization = Get-AvmBicepModuleInitializationPlan -Path $Path -ModuleType $ModuleType `
            -InputObject $InputObject -AncestorInputObject $AncestorInputObject `
            -ChildModule:$ChildModule -SkipModuleVersionCheck:$SkipModuleVersionCheck
        $root = $initialization.Root
        $plans = $initialization.Plans
        Test-AvmModuleInitializationPlan -Root $root -Plan $plans
        $changed = $false
        if ($plans.Count -gt 0 -and $PSCmdlet.ShouldProcess($root, 'Initialize local Bicep module files')) {
            $changed = Write-AvmModuleInitializationPlan -Root $root -Plan $plans -Confirm:$false
        }
        return [pscustomobject][ordered]@{
            Engine       = $Ecosystem
            Tool         = 'module-initialize/1'
            ToolPath     = $null
            ToolSource   = 'builtin'
            Status       = 'pass'
            Issues       = @()
            Changed      = $changed
            PlannedFiles = @($plans | ForEach-Object { [System.IO.Path]::GetRelativePath($root, $_.Path).Replace('\', '/') })
            Metadata     = $initialization.Metadata
        }
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
        Confirm                = $false
    }
    if (-not $WhatIfPreference -and
        -not (Test-Path -LiteralPath (Join-Path -Path $Path -ChildPath 'metadata.json')) -and
        -not $PSCmdlet.ShouldProcess($Path, 'Initialize local module metadata')) {
        return
    }
    return Initialize-AvmModuleMetadata @parameters
}
