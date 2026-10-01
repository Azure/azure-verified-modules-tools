function Get-AvmApplicationPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('git', 'gh')]
        [string] $Name
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $application = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $application) {
        $hint = if ($Name -eq 'gh') {
            'Install the GitHub CLI from https://cli.github.com and run gh auth login.'
        }
        else {
            'Install Git from https://git-scm.com/downloads.'
        }
        throw [AvmConfigurationException]::new("$Name was not found on PATH. $hint")
    }
    return $application.Source
}
