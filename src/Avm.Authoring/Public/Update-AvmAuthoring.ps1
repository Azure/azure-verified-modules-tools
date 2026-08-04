function Update-AvmAuthoring {
    <#
    .SYNOPSIS
        Update Avm.Authoring to the latest PowerShell Gallery version.

    .DESCRIPTION
        Queries the same cached PowerShell Gallery version used by the normal
        stale-version gate. If the running module is outdated, safely invokes
        Update-PSResource for the CurrentUser scope. This command intentionally
        bypasses stale-version enforcement so an outdated module can update
        itself.

        Routed by the dispatcher: 'avm update'.

    .EXAMPLE
        avm update

    .EXAMPLE
        avm update --what-if
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    try {
        $latestVersion = Get-AvmLatestModuleVersion
    }
    catch {
        throw [AvmToolException]::new(
            "Unable to determine the latest Avm.Authoring version from PowerShell Gallery. Verify PSGallery connectivity and try 'avm update' again. $($_.Exception.Message)",
            $_.Exception)
    }

    $currentModule = Get-Module -Name 'Avm.Authoring' |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $currentModule) {
        throw [AvmConfigurationException]::new(
            'Unable to determine the running Avm.Authoring version. Re-import Avm.Authoring and run ''avm update'' again.')
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
            Repository  = 'PSGallery'
            Version     = $latestVersion.ToString()
            Confirm     = $false
            PassThru    = $true
            ErrorAction = 'Stop'
        }
        $null = Update-PSResource @updateParameters
    }
    catch {
        throw [AvmToolException]::new(
            "Failed to update Avm.Authoring from $currentVersion to $latestVersion. Verify PSGallery connectivity and CurrentUser module-path permissions, then run 'Update-PSResource -Name Avm.Authoring -Scope CurrentUser' directly. $($_.Exception.Message)",
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
