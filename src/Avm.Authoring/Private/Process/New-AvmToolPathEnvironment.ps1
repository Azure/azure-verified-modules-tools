function New-AvmToolPathEnvironment {
    <#
    .SYNOPSIS
        Build a child-process PATH containing only the resolved copy of a tool.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $ToolPath,

        [Parameter(Mandatory)]
        [string] $ToolName,

        [AllowEmptyString()]
        [string] $Path = $env:PATH
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $toolDirectory = Split-Path -Parent $ToolPath
    if ([string]::IsNullOrWhiteSpace($toolDirectory)) {
        throw [System.ArgumentException]::new(
            "ToolPath must include a parent directory (got '$ToolPath').")
    }

    $entrypoint = if ([OperatingSystem]::IsWindows()) {
        "$ToolName.exe"
    }
    else {
        $ToolName
    }

    $separator = [System.IO.Path]::PathSeparator
    $safeEntries = [System.Collections.Generic.List[string]]::new()
    $removed = 0
    foreach ($entry in @($Path -split [regex]::Escape([string]$separator))) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $entry $entrypoint) -PathType Leaf -ErrorAction SilentlyContinue) {
            $removed++
            continue
        }
        $safeEntries.Add($entry)
    }

    $entries = [System.Collections.Generic.List[string]]::new()
    $entries.Add($toolDirectory)
    $entries.AddRange($safeEntries)

    Write-AvmLog ("path-env: prepended {0} for {1}; removed {2} conflicting path entry/entries" -f $toolDirectory, $ToolName, $removed) -Level Verbose | Out-Null
    return @{
        PATH = $entries -join $separator
    }
}
