function Get-AvmBicepConventionWorkflow {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $version = [version]'0.4.12'
    $installed = @(Get-Module -ListAvailable -Name 'powershell-yaml' |
            Where-Object { $_.Version -eq $version })
    if ($installed.Count -eq 0) {
        throw [AvmConfigurationException]::new(
            'Bicep workflow checks require powershell-yaml 0.4.12. Install-PSResource -Name powershell-yaml -Version 0.4.12 -Scope CurrentUser; no workflow was inspected.')
    }

    try {
        $parser = Import-Module -Name 'powershell-yaml' -RequiredVersion $version -PassThru -ErrorAction Stop
        $command = $parser.ExportedCommands['ConvertFrom-Yaml']
        if ($null -eq $command) {
            throw [AvmConfigurationException]::new('powershell-yaml 0.4.12 does not export ConvertFrom-Yaml.')
        }
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
        $workflow = & $command -Yaml $text -ErrorAction Stop
    }
    catch {
        throw [AvmConfigurationException]::new(
            "Bicep workflow '$Path' could not be parsed with powershell-yaml 0.4.12: $($_.Exception.Message)")
    }

    if ($workflow -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new("Bicep workflow '$Path' must contain a YAML mapping.")
    }
    return $workflow
}
