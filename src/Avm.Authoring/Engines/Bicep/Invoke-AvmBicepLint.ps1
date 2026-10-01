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

        Bicep lint errors, including nonzero exits without a parseable
        diagnostic, fail the check. AVM_OFFLINE=1 disables external module
        restoration.

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
    Write-AvmLog ("lint: discovered {0} bicep file(s)" -f $files.Count) -Level Verbose | Out-Null

    $issues = New-Object System.Collections.Generic.List[object]
    $fileIndex = 0
    foreach ($file in $files) {
        $fileIndex++
        Write-AvmLog ("lint: file {0}/{1} = {2}" -f $fileIndex, $files.Count, $file.FullName) -Level Info | Out-Null
        $arguments = @('lint', $file.FullName, '--diagnostics-format', 'defaultV2')
        if ($env:AVM_OFFLINE -eq '1') {
            $arguments += '--no-restore'
        }
        $r = Invoke-AvmProcess `
            -FilePath $tool.Path `
            -ArgumentList $arguments `
            -IgnoreExitCode `
            -StreamOutput `
            -Label ("bicep lint {0}" -f $file.Name)

        $stream = if ($r.StdErr) { $r.StdErr } else { $r.StdOut }
        $hasError = $false
        foreach ($line in ($stream -split "`r?`n")) {
            if (-not $line) { continue }
            # <path>(<l>,<c>) : <severity> <code>: <message>
            if ($line -match '^(?<path>.+?)\((?<l>\d+),(?<c>\d+)\)\s*:\s*(?<sev>\w+)\s+(?<code>[^:]+)\s*:\s*(?<msg>.*)$') {
                $severity = $Matches['sev'].ToLowerInvariant()
                if ($severity -eq 'error') { $hasError = $true }
                $issues.Add([pscustomobject][ordered]@{
                        File     = $Matches['path']
                        Line     = [int]$Matches['l']
                        Column   = [int]$Matches['c']
                        Severity = $severity
                        Code     = $Matches['code'].Trim()
                        Message  = $Matches['msg'].Trim()
                    })
            }
        }
        if ($r.ExitCode -ne 0 -and -not $hasError) {
            $detail = if ([string]::IsNullOrWhiteSpace($r.StdErr)) { [string]$r.StdOut } else { [string]$r.StdErr }
            $issues.Add([pscustomobject][ordered]@{
                    File     = $file.FullName
                    Line     = 0
                    Column   = 0
                    Severity = 'error'
                    Code     = 'avm.bicep.lint-failed'
                    Message  = "Bicep lint exited with code $($r.ExitCode): $detail"
                })
        }
    }

    $status = if ($issues | Where-Object { $_.Severity -eq 'error' }) { 'fail' } else { 'pass' }
    Write-AvmLog ("lint: bicep completed with {0} issue(s)" -f $issues.Count) -Level Verbose | Out-Null

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
