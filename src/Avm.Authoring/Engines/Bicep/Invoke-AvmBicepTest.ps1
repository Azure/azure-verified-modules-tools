function Invoke-AvmBicepTest {
    <#
    .SYNOPSIS
        Compile every .bicep source under the module root with 'bicep build'
        as a build-validation pass.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmTest when the module
        context is Ecosystem='bicep'. Runs 'bicep build --stdout <file>' for
        each .bicep file under $Context.Root (skipping dot-folders and
        node_modules). Compilation failures are surfaced as Issue records;
        any failure flips Status to 'fail'.

        bicep build emits diagnostics to stderr in the same defaultV2 format
        as bicep lint:
          <path>(<line>,<col>) : <severity> <code>: <message>

        and exits non-zero on a failed build. This engine sets
        -IgnoreExitCode, inspects parsed diagnostics, and reports any
        nonzero exit without a parsed error so a failed build cannot pass.

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
            "Invoke-AvmBicepTest requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
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
            -ArgumentList @('build', '--stdout', $file.FullName) `
            -IgnoreExitCode

        $stream = if ($r.StdErr) { $r.StdErr } else { '' }
        $hasError = $false
        foreach ($line in ($stream -split "`r?`n")) {
            if (-not $line) { continue }
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
                    Code     = 'avm.bicep.build-failed'
                    Message  = "Bicep build exited with code $($r.ExitCode): $detail"
                })
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
