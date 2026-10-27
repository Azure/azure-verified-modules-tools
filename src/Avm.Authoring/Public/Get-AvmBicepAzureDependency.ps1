function Get-AvmBicepAzureDependency {
    <#
    .SYNOPSIS
        List Azure PowerShell dependencies required for Bicep deployment tests.

    .DESCRIPTION
        Returns the module names and minimum versions used by the Bicep cleanup
        preflight. It does not install or import modules, authenticate, or
        submit deployments. Install dependencies separately and use a fresh
        PowerShell session for deployment tests.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery check for a newer Avm.Authoring release.

    .OUTPUTS
        PSCustomObject with Name and MinimumVersion properties.

    .EXAMPLE
        Get-AvmBicepAzureDependency
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch] $SkipModuleVersionCheck)

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    foreach ($requirement in Get-AvmBicepAzureRequirement) {
        [pscustomobject]@{
            Name           = $requirement.Name
            MinimumVersion = [version]$requirement.MinimumVersion
        }
    }
}
