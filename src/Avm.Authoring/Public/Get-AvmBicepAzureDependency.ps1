function Get-AvmBicepAzureDependency {
    <#
    .SYNOPSIS
        List Azure PowerShell dependencies required for Bicep deployment tests.

    .DESCRIPTION
        Returns the individual module names and minimum versions used by the
        Bicep cleanup preflight. It does not install or import modules,
        authenticate, or submit deployments. Bicep deployment and cleanup
        resolve missing pinned modules on demand through the managed dependency
        cache. Existing compatible module versions remain usable.

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
