function Test-AvmModuleVersion {
    [CmdletBinding()]
    param(
        [switch] $SkipModuleVersionCheck,

        [switch] $SuppressSkipWarning,

        [switch] $RefreshLatestVersion
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $testRunId = $env:AVM_TEST_RUN_ID
    $parsedTestRunId = [guid]::Empty
    $hasTestRunId = -not [string]::IsNullOrWhiteSpace($testRunId)
    $hasValidTestRunId = [guid]::TryParse($testRunId, [ref]$parsedTestRunId)
    $isRepositoryTestRun = $hasTestRunId -and $hasValidTestRunId -and ($env:AVM_TEST_SKIP_MODULE_VERSION_CHECK -ceq $testRunId)
    if ($isRepositoryTestRun) {
        return
    }

    if ($SkipModuleVersionCheck) {
        if (-not $SuppressSkipWarning -and -not $script:AvmModuleVersionSkipWarningWritten) {
            Write-Warning 'The Avm.Authoring PowerShell Gallery version check was skipped. The current command may run with an outdated module.'
            $script:AvmModuleVersionSkipWarningWritten = $true
        }
        return
    }

    try {
        $latestVersion = Get-AvmLatestModuleVersion -Refresh:$RefreshLatestVersion
    }
    catch {
        $failure = $_.Exception
        $detail = if ($failure -is [AvmGalleryLookupException]) {
            $failure.Message
        }
        elseif ($failure -is [System.Net.Http.HttpRequestException]) {
            'The Gallery request failed.'
        }
        elseif ($failure -is [System.TimeoutException] -or
            $failure -is [System.Threading.Tasks.TaskCanceledException]) {
            'The Gallery request timed out.'
        }
        else {
            'The Gallery lookup failed unexpectedly.'
        }
        Write-Warning "Unable to check PowerShell Gallery for the latest Avm.Authoring version. Continuing with the installed module. $detail"
        return
    }

    $currentModule = Get-Module -Name 'Avm.Authoring' |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $currentModule) {
        Write-Warning 'Unable to determine the running Avm.Authoring version. Continuing without enforcing the PowerShell Gallery version.'
        return
    }

    Write-AvmLog (
        'module version check: comparing running version {0} with latest PowerShell Gallery version {1}' -f
        $currentModule.Version,
        $latestVersion) -Level Verbose

    if ($currentModule.Version -lt $latestVersion) {
        $upgradeScript = 'Update-PSResource -Name Avm.Authoring -Scope CurrentUser'
        $reloadScript = 'Import-Module Avm.Authoring -Force'
        throw [AvmModuleVersionException]::new(
            $currentModule.Version,
            $latestVersion,
            "Avm.Authoring $($currentModule.Version) is outdated; the latest PowerShell Gallery version is $latestVersion. Upgrade and reload the module in this PowerShell process:`n$upgradeScript`n$reloadScript")
    }
}
