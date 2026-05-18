function Invoke-AvmBicepLint {
    <#
    .SYNOPSIS
        Run 'bicep lint' over every .bicep source under the resolved module
        root and collect the diagnostics into a normalised Issues array.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmLint when the module
        context is Ecosystem='bicep'. Discovers all .bicep files (skipping
        dot-folders and node_modules), runs 'bicep lint <file> --diagnostics-format
        defaultV2' per file via Invoke-AvmProcess, and parses the textual
        diagnostics into structured Issue objects.

        Each diagnostic line looks like:
          <path>(<line>,<col>) : <severity> <code>: <message>

        bicep lint returns exit code 1 when at least one Error diagnostic
        was emitted and 0 otherwise (warnings and info do not change the
        exit code). The engine surfaces that as Status='fail' when any
        Issue has Severity='error', otherwise 'pass'.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmBicepLint requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback

    $discovered = Get-ChildItem -Path $Context.Root -Recurse -File -Filter '*.bicep' -ErrorAction Stop |
        Where-Object { $_.FullName -notmatch '[\\/]\.[^\\/]+[\\/]' } |
        Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' }
    $files = @($discovered)

    $issues = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        $r = Invoke-AvmProcess `
            -FilePath $tool.Path `
            -ArgumentList @('lint', $file.FullName, '--diagnostics-format', 'defaultV2') `
            -IgnoreExitCode

        $stream = if ($r.StdErr) { $r.StdErr } else { $r.StdOut }
        foreach ($line in ($stream -split "`r?`n")) {
            if (-not $line) { continue }
            # <path>(<l>,<c>) : <severity> <code>: <message>
            if ($line -match '^(?<path>.+?)\((?<l>\d+),(?<c>\d+)\)\s*:\s*(?<sev>\w+)\s+(?<code>[^:]+)\s*:\s*(?<msg>.*)$') {
                $issues.Add([pscustomobject][ordered]@{
                        File     = $Matches['path']
                        Line     = [int]$Matches['l']
                        Column   = [int]$Matches['c']
                        Severity = $Matches['sev'].ToLowerInvariant()
                        Code     = $Matches['code'].Trim()
                        Message  = $Matches['msg'].Trim()
                    })
            }
        }
    }

    $status = if ($issues | Where-Object { $_.Severity -eq 'error' }) { 'fail' } else { 'pass' }

    return [pscustomobject][ordered]@{
        Engine         = 'bicep'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        Status         = $status
        FilesProcessed = $files.Count
        Issues         = $issues.ToArray()
    }
}
