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

    try {
        $latestVersion = Get-AvmLatestModuleVersion
    }
    catch {
        Write-Warning "Unable to check PowerShell Gallery for the latest Avm.Authoring version. Continuing with the installed module. $($_.Exception.Message)"
        return
    }

    $currentModule = Get-Module -Name 'Avm.Authoring' |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $currentModule) {
        Write-Warning 'Unable to determine the running Avm.Authoring version. Continuing without enforcing the PowerShell Gallery version.'
        return
    }

    if ($currentModule.Version -lt $latestVersion) {
        $upgradeScript = 'Update-PSResource -Name Avm.Authoring -Scope CurrentUser'
        throw [AvmModuleVersionException]::new(
            $currentModule.Version,
            $latestVersion,
            "Avm.Authoring $($currentModule.Version) is outdated. The latest PowerShell Gallery version is $latestVersion. Running the latest version ensures current fixes and behavior. Upgrade with:`n$upgradeScript")
    }
}
