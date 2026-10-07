function Get-AvmPowerShellModulePin {
    <#
    .SYNOPSIS
        Return the exact pinned version of an on-demand PowerShell module.
    .DESCRIPTION
        Reads the effective powerShellModules pin for the selected module root.
        Throws when the module has no pin.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [string] $ModuleRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $pins = Read-AvmPins -ModuleRoot $ModuleRoot
    if (-not $pins.ContainsKey('powerShellModules')) {
        throw [System.Data.DataException]::new("avm.pins: missing 'powerShellModules'.")
    }
    if (-not $pins.powerShellModules.ContainsKey($Name)) {
        throw [System.Data.DataException]::new("avm.pins: no powerShellModules pin for '$Name'.")
    }
    return [version]$pins.powerShellModules[$Name].version
}