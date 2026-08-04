function Get-AvmLatestModuleVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($script:AvmModuleVersionCheckCompleted) {
        return $script:AvmLatestModuleVersion
    }

    $response = Invoke-RestMethod `
        -Uri "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='Avm.Authoring'&`$orderby=Version%20desc&`$top=1" `
        -Headers @{ Accept = 'application/json' } `
        -TimeoutSec 10

    $latestVersionText = [string]$response.value[0].Version
    if ([string]::IsNullOrWhiteSpace($latestVersionText)) {
        throw [System.InvalidOperationException]::new(
            'The PowerShell Gallery response did not contain an Avm.Authoring version.')
    }

    $script:AvmLatestModuleVersion = [version]$latestVersionText
    $script:AvmModuleVersionCheckCompleted = $true
    return $script:AvmLatestModuleVersion
}
