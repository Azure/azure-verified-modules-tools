function Install-AvmTool {
    <#
    .SYNOPSIS
        Install one, several, or all managed tools from tools.lock.

    .DESCRIPTION
        Routed by the dispatcher:
            avm tool install                        -> Install everything in the lock
            avm tool install terraform              -> Install just terraform
            avm tool install terraform bicep        -> Install both
            avm tool install --force terraform      -> Force-reinstall

        Each install goes through the atomic stage->rename pipeline implemented
        by Install-AvmToolFromLock: SHA256 verified before extraction, version
        directory renamed atomically into place, and a '.verified' marker
        written last so that interrupted installs are re-tried automatically.

    .PARAMETER Name
        One or more tool names from the lock. When omitted, every tool in
        the lock is installed.

    .PARAMETER Force
        Delete and reinstall, even if the cache already has a '.verified'
        entry for the requested version.

    .PARAMETER LockPath
        Override the bundled Resources/tools.lock.psd1. Intended for tests.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string[]] $Name,

        [switch] $Force,

        [string] $LockPath,

        # Test-only escape hatch (see Test-AvmToolsLock). Hidden from help
        # and tab-completion so it does not appear in the production surface.
        [Parameter(DontShow)]
        [switch] $AllowFileUrls
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $lock = if ($LockPath) {
        Read-AvmToolsLock -Path $LockPath -AllowFileUrls:$AllowFileUrls
    }
    else {
        Read-AvmToolsLock
    }
    $tools = @($lock.tools)

    if ($Name) {
        $requested = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($n in $Name) { [void]$requested.Add($n) }
        $tools = $tools | Where-Object { $requested.Contains($_.name) }
        $tools = @($tools)

        $found = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($t in $tools) { [void]$found.Add($t.name) }
        $missing = $Name | Where-Object { -not $found.Contains($_) }
        if ($missing) {
            throw [System.ArgumentException]::new(
                "Unknown tool(s) in lock: $($missing -join ', ').")
        }
    }

    if ($tools.Count -eq 0) {
        Write-Information 'No tools to install.' -InformationAction Continue
        return
    }

    $platform = Get-AvmToolPlatform
    foreach ($t in $tools) {
        Write-Information ("Installing {0} {1} ({2})..." -f $t.name, $t.version, $platform) -InformationAction Continue
        Install-AvmToolFromLock -Tool $t -Platform $platform -Force:$Force
    }
}
