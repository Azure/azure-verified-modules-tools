function Import-AvmBicepPolicyModule {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string] $ModuleRoot)

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $required = @('PSRule', 'PSRule.Rules.Azure' | ForEach-Object {
            [pscustomobject]@{ Name = $_; Version = Get-AvmPowerShellModulePin -Name $_ -ModuleRoot $ModuleRoot }
        })
    $loaded = @{}
    foreach ($module in $required) {
        try {
            $loaded[$module.Name] = Import-AvmPowerShellModule -Name $module.Name -ModuleRoot $ModuleRoot -Global
        }
        catch {
            throw [AvmConfigurationException]::new(
                ("Bicep policy could not load {0} {1}: {2}" -f $module.Name, $module.Version, $_.Exception.Message))
        }
    }
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    foreach ($name in $loaded.Keys) {
        $visible = @(Get-Module -Name $name)
        if ($visible.Count -eq 0 -or @($visible | Where-Object {
                    $_.Version -ne $loaded[$name].Version -or
                    -not [string]::Equals($_.ModuleBase, $loaded[$name].ModuleBase, $comparison)
                }).Count -gt 0) {
            throw [AvmConfigurationException]::new(
                "Bicep policy requires only the selected '$name' module at '$($loaded[$name].ModuleBase)'. Retry in a fresh PowerShell session.")
        }
    }
    return [pscustomobject]@{
        Name = ($required | ForEach-Object { '{0}/{1}' -f $_.Name, $_.Version }) -join ' + '
        Path = $loaded.PSRule.Path
    }
}