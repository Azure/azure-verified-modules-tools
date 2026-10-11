function Get-AvmBicepConventionWorkflow {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $ModuleRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $version = Get-AvmPowerShellModulePin -Name 'powershell-yaml' -ModuleRoot $ModuleRoot

    try {
        $parser = Import-AvmPowerShellModule -Name 'powershell-yaml' -ModuleRoot $ModuleRoot
        $command = $parser.ExportedCommands['ConvertFrom-Yaml']
        if ($null -eq $command) {
            throw [AvmConfigurationException]::new("powershell-yaml $version does not export ConvertFrom-Yaml.")
        }
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
        $workflow = & $command -Yaml $text -ErrorAction Stop
    }
    catch {
        throw [AvmConfigurationException]::new(
            "Bicep workflow '$Path' could not be parsed with powershell-yaml $($version): $($_.Exception.Message)")
    }

    if ($workflow -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new("Bicep workflow '$Path' must contain a YAML mapping.")
    }
    return $workflow
}
