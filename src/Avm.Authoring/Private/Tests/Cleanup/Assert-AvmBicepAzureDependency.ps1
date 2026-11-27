function Assert-AvmBicepAzureDependency {
    [CmdletBinding()]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($requirement in Get-AvmBicepAzureRequirement) {
        $minimum = [version]$requirement.MinimumVersion
        $loaded = @(Get-Module -Name $requirement.Name)
        $loadedOlder = @($loaded |
                Where-Object { $_.Version -lt $minimum })
        if ($loadedOlder.Count -gt 0) {
            throw [AvmConfigurationException]::new(
                "An older $($requirement.Name) is loaded. Start a fresh PowerShell session with version $minimum or newer before running Bicep deployment tests.")
        }
        $loadedEligible = @($loaded |
                Where-Object { $_.Version -ge $minimum } |
                Sort-Object -Property Version -Descending)
        if ($loadedEligible.Count -gt 0) {
            $selected.Add(@{ Module = $loadedEligible[0]; Requirement = $requirement })
        }
        else {
            $available = @(Get-Module -ListAvailable -Name $requirement.Name |
                    Where-Object { $_.Version -ge $minimum } |
                    Sort-Object -Property Version -Descending)
            if ($available.Count -gt 0) {
                $selected.Add(@{ Module = $available[0]; Requirement = $requirement })
            }
            else {
                $resolved = Resolve-AvmTool -Name $requirement.Name
                $selected.Add(@{
                        Module      = [pscustomobject]@{
                            Name = $resolved.Name; Version = $resolved.Version; Path = $resolved.Path
                        }
                        Requirement = $requirement
                    })
            }
        }
    }

    foreach ($entry in $selected) {
        # Nested Az clients resolve Accounts from the global session scope.
        Import-Module -Name $entry.Module.Path -Global:($entry.Requirement.Name -ceq 'Az.Accounts') -ErrorAction Stop
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
