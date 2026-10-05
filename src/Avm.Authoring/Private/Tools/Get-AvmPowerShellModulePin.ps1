function Get-AvmPowerShellModulePin {
    <#
    .SYNOPSIS
        Return the exact pinned version of an on-demand PowerShell module.
    .DESCRIPTION
        Reads the powerShellModules section of Resources/avm.pins.jsonc once per
        session. Throws when the module has no pin.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Get-Variable -Name AvmPowerShellModulePins -Scope Script -ErrorAction Ignore) -or
        $null -eq $script:AvmPowerShellModulePins) {
        $pins = Read-AvmPins
        if (-not $pins.ContainsKey('powerShellModules')) {
            throw [System.Data.DataException]::new("avm.pins: missing 'powerShellModules'.")
        }
        $script:AvmPowerShellModulePins = $pins['powerShellModules']
    }
    if (-not $script:AvmPowerShellModulePins.ContainsKey($Name)) {
        throw [System.Data.DataException]::new("avm.pins: no powerShellModules pin for '$Name'.")
    }
    return [version]$script:AvmPowerShellModulePins[$Name]
}