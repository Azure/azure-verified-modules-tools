function Test-AvmInteractiveHost {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        if (-not [string]::IsNullOrEmpty($env:CI)) { return $false }
        if (Test-AvmGitHubActionsContext) { return $false }
        if ([System.Console]::IsInputRedirected) { return $false }
        if ($null -eq $Host.UI) { return $false }
        if (@([System.Environment]::GetCommandLineArgs()) -contains '-NonInteractive') { return $false }
    }
    catch {
        return $false
    }

    return $true
}
