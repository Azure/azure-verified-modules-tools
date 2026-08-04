function Test-AvmModuleVersion {
    [CmdletBinding()]
    param(
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($SkipModuleVersionCheck) {
        if (-not $script:AvmModuleVersionSkipWarningWritten) {
            Write-Warning 'The Avm.Authoring PowerShell Gallery version check was skipped. The current command may run with an outdated module.'
            $script:AvmModuleVersionSkipWarningWritten = $true
        }
        return
    }

    if (-not $script:AvmModuleVersionCheckCompleted) {
        try {
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
        }
        catch {
            Write-Warning "Unable to check PowerShell Gallery for the latest Avm.Authoring version. Continuing with the installed module. $($_.Exception.Message)"
            return
        }
    }

    $currentModule = Get-Module -Name 'Avm.Authoring' |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $currentModule) {
        Write-Warning 'Unable to determine the running Avm.Authoring version. Continuing without enforcing the PowerShell Gallery version.'
        return
    }

    if ($currentModule.Version -lt $script:AvmLatestModuleVersion) {
        $upgradeScript = 'Update-PSResource -Name Avm.Authoring -Scope CurrentUser'
        throw [AvmModuleVersionException]::new(
            $currentModule.Version,
            $script:AvmLatestModuleVersion,
            "Avm.Authoring $($currentModule.Version) is outdated. The latest PowerShell Gallery version is $script:AvmLatestModuleVersion. Running the latest version ensures current fixes and behavior. Upgrade with:`n$upgradeScript")
    }
}
