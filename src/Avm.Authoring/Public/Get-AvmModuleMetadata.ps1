function Get-AvmModuleMetadata {
    <#
    .SYNOPSIS
        Read and validate an existing module metadata.json file.
    .DESCRIPTION
        Returns validated metadata or explicit diagnostics without writing files
        or deriving values from other sources. Missing files are reported as
        failures. Bicep name and description are also checked against source.
    .PARAMETER Path
        Directory containing metadata.json.
    .PARAMETER Ecosystem
        bicep or terraform.
    .PARAMETER ModuleType
        resource, pattern, or utility.
    .PARAMETER ChildModule
        Require the reduced child shape, without owners.
        This scope also permits canonicalType helper with optional telemetry.
    .PARAMETER SkipModuleVersionCheck
        Skip the installed-module version check for offline reading.
    .EXAMPLE
        Get-AvmModuleMetadata -Path . -Ecosystem terraform -ModuleType resource
    .OUTPUTS
        A result with Status, Issues, and the decoded Metadata.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Metadata is the shared metadata.json contract name.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = $PWD.Path,
        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,
        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,
        [switch] $ChildModule,
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    return Test-AvmModuleMetadata -Path $Path -Ecosystem $Ecosystem -ModuleType $ModuleType `
        -ChildModule:$ChildModule -CheckSource:($Ecosystem -eq 'bicep') -SkipModuleVersionCheck
}
