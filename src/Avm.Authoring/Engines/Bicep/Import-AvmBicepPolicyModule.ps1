function Import-AvmBicepPolicyModule {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    foreach ($required in @(
            [pscustomobject]@{ Name = 'PSRule'; Version = '2.9.0' }
            [pscustomobject]@{ Name = 'PSRule.Rules.Azure'; Version = '1.47.0' }
        )) {
        $installed = @(Get-Module -ListAvailable -Name $required.Name |
                Where-Object { $_.Version -eq [version]$required.Version })
        if ($installed.Count -eq 0) {
            throw [AvmConfigurationException]::new(
                ("Bicep policy requires {0} {1}. Install-PSResource -Name {0} -Version {1} -Scope CurrentUser; the module is not installed automatically." -f $required.Name, $required.Version))
        }
        try {
            Import-Module -Name $required.Name -RequiredVersion $required.Version -ErrorAction Stop
        }
        catch {
            throw [AvmConfigurationException]::new(
                ("Bicep policy could not load {0} {1}. Reinstall that exact version with Install-PSResource." -f $required.Name, $required.Version))
        }
    }
    $engine = Get-Module -Name PSRule | Where-Object { $_.Version -eq [version]'2.9.0' } |
        Select-Object -First 1
    if ($null -eq $engine) {
        throw [AvmConfigurationException]::new('Bicep policy could not verify the loaded PSRule engine.')
    }
    return [pscustomobject]@{
        Name = 'PSRule/2.9.0 + PSRule.Rules.Azure/1.47.0'
        Path = $engine.Path
    }
}
