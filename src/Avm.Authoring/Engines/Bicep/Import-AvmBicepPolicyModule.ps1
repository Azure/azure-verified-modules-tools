function Import-AvmBicepPolicyModule {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $required = @('PSRule', 'PSRule.Rules.Azure' | ForEach-Object {
            [pscustomobject]@{ Name = $_; Version = Get-AvmPowerShellModulePin -Name $_ }
        })
    foreach ($module in $required) {
        $installed = @(Get-Module -ListAvailable -Name $module.Name |
                Where-Object { $_.Version -eq $module.Version })
        if ($installed.Count -eq 0) {
            throw [AvmConfigurationException]::new(
                ("Bicep policy requires {0} {1}. Install-PSResource -Name {0} -Version {1} -Scope CurrentUser; the module is not installed automatically." -f $module.Name, $module.Version))
        }
        try {
            Import-Module -Name $module.Name -RequiredVersion $module.Version -ErrorAction Stop
        }
        catch {
            throw [AvmConfigurationException]::new(
                ("Bicep policy could not load {0} {1}. Reinstall that exact version with Install-PSResource." -f $module.Name, $module.Version))
        }
    }
    $engine = Get-Module -Name PSRule | Where-Object { $_.Version -eq $required[0].Version } |
        Select-Object -First 1
    if ($null -eq $engine) {
        throw [AvmConfigurationException]::new('Bicep policy could not verify the loaded PSRule engine.')
    }
    return [pscustomobject]@{
        Name = ($required | ForEach-Object { '{0}/{1}' -f $_.Name, $_.Version }) -join ' + '
        Path = $engine.Path
    }
}