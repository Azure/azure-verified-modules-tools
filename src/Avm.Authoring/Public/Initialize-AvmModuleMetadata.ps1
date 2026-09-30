function Initialize-AvmModuleMetadata {
    <#
    .SYNOPSIS
        Create metadata.json without overwriting an existing file.
    .DESCRIPTION
        Validates the metadata values before writing UTF-8/LF metadata.json.
        Existing metadata is validated and preserved instead of regenerated.
        Missing required values are prompted for in an interactive terminal;
        non-interactive callers must supply them explicitly. A missing Bicep
        prefix is generated against published and local metadata when required.
        A missing Bicep module directory is created after validation.
        Optional Bicep source wiring loads the telemetry prefix without changing
        its transport. Terraform source wiring is not supported.
        WhatIf performs validation and returns the plan.
    .PARAMETER Path
        Module directory to initialize. Missing Bicep directories are created
        after validation; Terraform requires an existing directory by default.
    .PARAMETER InputObject
        Optional metadata values supplied by the caller. Supplied values must be
        valid; absent required values are prompted for only in interactive hosts.
    .PARAMETER Ecosystem
        The containing module's ecosystem: bicep or terraform.
    .PARAMETER ModuleType
        Module kind derived from its path or repository name.
    .PARAMETER ChildModule
        Initialize the reduced child shape, inheriting root ownership.
        This scope also permits canonicalType helper with optional telemetry.
    .PARAMETER UpdateSource
        Wire Bicep's scoped telemetry prefix load. Existing conflicting readers
        are not replaced. Terraform rejects this switch before any writes.
    .PARAMETER CreateDirectory
        Explicitly permit creating a missing Terraform module directory. Used
        by local avm init; legacy Terraform callers still require an existing
        module directory by default.
    .PARAMETER SkipModuleVersionCheck
        Skip the standard installed-module version check for offline initialization.
    .EXAMPLE
        Initialize-AvmModuleMetadata -Path . -InputObject $metadata -Ecosystem terraform -ModuleType resource -WhatIf
    .OUTPUTS
        A result with Status, Changed, PlannedFiles, and Metadata.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Metadata is the shared metadata.json contract name.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = $PWD.Path,

        [System.Collections.IDictionary] $InputObject = @{},

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [switch] $ChildModule,

        [switch] $UpdateSource,

        [switch] $CreateDirectory,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $initialization = Get-AvmModuleMetadataInitializationPlan -Path $Path -InputObject $InputObject `
        -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule `
        -UpdateSource:$UpdateSource -CreateDirectory:$CreateDirectory `
        -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $root = $initialization.Root
    $plans = $initialization.Plans

    $changed = $false
    if ($plans.Count -gt 0 -and $PSCmdlet.ShouldProcess($root, 'Initialize module metadata and requested JSON source readers')) {
        $changed = Write-AvmModuleInitializationPlan -Root $root -Plan $plans -Confirm:$false
    }

    return [pscustomobject][ordered]@{
        Engine       = $Ecosystem
        Tool         = 'module-metadata/1'
        ToolPath     = $null
        ToolSource   = 'builtin'
        Status       = 'pass'
        Issues       = @()
        Changed      = $changed
        PlannedFiles = @($plans | ForEach-Object { [System.IO.Path]::GetRelativePath($root, $_.Path).Replace('\', '/') })
        Metadata     = $initialization.Metadata
    }
}
