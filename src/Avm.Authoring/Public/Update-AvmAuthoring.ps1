function Update-AvmAuthoring {
    <#
    .SYNOPSIS
        Update Avm.Authoring using the configured PowerShell repositories.

    .DESCRIPTION
        Queries every configured PowerShell repository and selects the highest
        published version. When repositories have the same highest version,
        uses configured priority order, then repository name. MAR hosts the
        module at mcr.microsoft.com/psresource/avm.authoring; PSResourceGet handles
        that registry prefix while the module name remains Avm.Authoring. If the
        running module is outdated, safely invokes Update-PSResource for the
        CurrentUser scope. This command bypasses stale-version enforcement so
        an outdated module can update itself. Update attempts use the configured
        repositories that reported that exact version in the same order until
        one succeeds. No repository receives special priority by name or URI.

        Routed by the dispatcher: 'avm upgrade'.

    .EXAMPLE
        avm upgrade

    .EXAMPLE
        avm upgrade --what-if

    .OUTPUTS
        System.Management.Automation.PSObject
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    try {
        $release = Get-AvmLatestModuleVersion -IncludeRepository
        $latestVersion = $release.Version
    }
    catch {
        throw [AvmToolException]::new(
            "Unable to determine the latest Avm.Authoring version from the configured PowerShell repositories. Verify repository configuration and connectivity and try 'avm upgrade' again. $($_.Exception.Message)",
            $_.Exception)
    }

    $currentModule = Get-Module -Name 'Avm.Authoring' |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $currentModule) {
        throw [AvmConfigurationException]::new(
            'Unable to determine the running Avm.Authoring version. Re-import Avm.Authoring and run ''avm upgrade'' again.')
    }

    $currentVersion = [version]$currentModule.Version
    if ($currentVersion -ge $latestVersion) {
        $message = "Avm.Authoring $currentVersion is already current."
        Write-AvmLog $message -Level Info
        return [pscustomobject]@{
            Name           = 'Avm.Authoring'
            Status         = 'current'
            CurrentVersion = $currentVersion
            LatestVersion  = $latestVersion
            Message        = $message
        }
    }

    $action = "Update from $currentVersion to $latestVersion in the CurrentUser scope"
    if (-not $PSCmdlet.ShouldProcess('Avm.Authoring', $action)) {
        return [pscustomobject]@{
            Name           = 'Avm.Authoring'
            Status         = 'skipped'
            CurrentVersion = $currentVersion
            LatestVersion  = $latestVersion
            Message        = 'The update was not invoked.'
        }
    }

    try {
        $updateParameters = @{
            Name        = 'Avm.Authoring'
            Scope       = 'CurrentUser'
            Version     = $latestVersion.ToString()
            Confirm     = $false
            PassThru    = $true
            ErrorAction = 'Stop'
        }
        $updateState = @{ Attempt = 0 }
        $null = Invoke-AvmPSRepositoryOperation -Repository $release.Repositories -Action {
            param($RepositoryName)
            $updateParameters.Repository = $RepositoryName
            Invoke-AvmRetry -RetryActivity 'Avm.Authoring update' -RetryAction {
                $updateState.Attempt++
                # A lost response may hide a completed install; check before trying again.
                if ($updateState.Attempt -gt 1 -and
                    $null -ne (Get-InstalledPSResource -Name 'Avm.Authoring' -Version $latestVersion.ToString() -Scope CurrentUser -ErrorAction SilentlyContinue)) {
                    return
                }
                $null = Update-PSResource @updateParameters
                if ($null -eq (Get-InstalledPSResource -Name 'Avm.Authoring' -Version $latestVersion.ToString() -Scope CurrentUser -ErrorAction SilentlyContinue)) {
                    throw [InvalidOperationException]::new("Repository '$RepositoryName' did not provide Avm.Authoring $latestVersion.")
                }
            }
        }
    }
    catch {
        throw [AvmToolException]::new(
            "Failed to update Avm.Authoring from $currentVersion to $latestVersion. Verify configured PowerShell repository connectivity and CurrentUser module-path permissions, then run 'Update-PSResource -Name Avm.Authoring -Scope CurrentUser' directly. $($_.Exception.Message)",
            $_.Exception)
    }

    $message = "Avm.Authoring was updated from $currentVersion to $latestVersion. Start a new PowerShell session or run 'Import-Module Avm.Authoring -Force' before using avm again."
    Write-AvmLog $message -Level Info
    return [pscustomobject]@{
        Name           = 'Avm.Authoring'
        Status         = 'updated'
        CurrentVersion = $currentVersion
        LatestVersion  = $latestVersion
        Message        = $message
    }
}
