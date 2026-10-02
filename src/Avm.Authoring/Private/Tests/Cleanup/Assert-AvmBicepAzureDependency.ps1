function Assert-AvmBicepAzureDependency {
    [CmdletBinding()]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $selected = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($requirement in Get-AvmBicepAzureRequirement) {
        $minimum = [version]$requirement.MinimumVersion
        $available = @(Get-Module -ListAvailable -Name $requirement.Name |
                Where-Object { $_.Version -ge $minimum } |
                Sort-Object -Property Version -Descending)
        if ($available.Count -eq 0) {
            $missing.Add("$($requirement.Name) >= $minimum")
            continue
        }
        $loadedOlder = @(Get-Module -Name $requirement.Name |
                Where-Object { $_.Version -lt $minimum })
        if ($loadedOlder.Count -gt 0) {
            throw [AvmConfigurationException]::new(
                "An older $($requirement.Name) is loaded. Start a fresh PowerShell session with version $minimum or newer before running Bicep deployment tests.")
        }
        $selected.Add(@{ Module = $available[0]; Requirement = $requirement })
    }
    if ($missing.Count -gt 0) {
        throw [AvmConfigurationException]::new(
            "Bicep cleanup dependencies are missing: $($missing -join ', '). Install the Az 15.5.0 bundle (or newer) and Az.Subscription 0.12.0 (or newer) in CurrentUser scope, then start a fresh PowerShell session. No modules were installed and no deployment was submitted.")
    }

    foreach ($entry in $selected) {
        Import-Module -Name $entry.Module.Path -ErrorAction Stop
        foreach ($commandName in $entry.Requirement.Commands.psbase.Keys) {
            $command = Get-Command -Name $commandName -ErrorAction Stop
            if ($command.ModuleName -ne $entry.Requirement.Name -or
                $command.Version -lt [version]$entry.Requirement.MinimumVersion) {
                throw [AvmConfigurationException]::new(
                    "Bicep cleanup command '$commandName' is not supplied by the required $($entry.Requirement.Name) version.")
            }
            foreach ($parameter in $entry.Requirement.Commands[$commandName]) {
                $supported = $command.Parameters.ContainsKey($parameter)
                if (-not $supported) {
                    $supported = @($command.Parameters.Values |
                            Where-Object { $_.Aliases -contains $parameter }).Count -gt 0
                }
                if (-not $supported) {
                    throw [AvmConfigurationException]::new(
                        "Bicep cleanup command '$commandName' lacks parameter '$parameter'; update $($entry.Requirement.Name) before deploying.")
                }
            }
        }
    }
}
