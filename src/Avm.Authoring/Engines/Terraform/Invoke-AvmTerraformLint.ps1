function Invoke-AvmTerraformLint {
    <#
    .SYNOPSIS
        Run 'tflint' against the resolved terraform module root.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmLint when the module
        context is Ecosystem='terraform'. Resolves 'tflint' via
        Resolve-AvmTool, runs '--recursive --format=json' against
        $Context.Root, then parses the JSON 'issues' array into the
        shared Issue record shape used by Invoke-AvmBicepLint.

        tflint exit codes:
          0  - no issues
          2  - issues found (treated as 'fail' only when severity=error)
          1  - tflint itself failed (treated as throw)

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

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

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformLint requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'tflint' -AllowPathFallback:$AllowPathFallback

    # Discover .tf files just for the FilesProcessed count; tflint walks
    # the working directory itself when given --recursive.
    $discovered = Get-ChildItem -LiteralPath $Context.Root -Recurse -File -Filter '*.tf' -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = [System.IO.Path]::GetRelativePath($Context.Root, $_.FullName)
            $parts = $rel -split '[\\/]'
            -not ($parts | Where-Object { $_.StartsWith('.') -or $_ -eq 'node_modules' })
        }
    $files = @($discovered)

    $result = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList @('--recursive', '--format=json') `
        -WorkingDirectory $Context.Root `
        -IgnoreExitCode

    # exit 0 = no issues; 2 = issues; anything else = tflint itself misbehaved.
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 2) {
        $stderr = if ($result.StdErr) { $result.StdErr.Trim() } else { '' }
        $tail = if ($stderr) { ": $stderr" } else { '.' }
        throw [AvmProcessException]::new(
            ('tflint exited with code {0}{1}' -f $result.ExitCode, $tail))
    }

    $issues = New-Object System.Collections.Generic.List[object]
    $payload = if ($result.StdOut) { $result.StdOut.Trim() } else { '' }
    if ($payload) {
        try {
            $parsed = $payload | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw [AvmProcessException]::new(
                "Could not parse tflint --format=json output: $($_.Exception.Message)")
        }
        if ($parsed -and ($parsed.PSObject.Properties.Name -contains 'issues')) {
            foreach ($issue in @($parsed.issues)) {
                $sev = if ($issue.rule -and $issue.rule.severity) { [string]$issue.rule.severity } else { 'warning' }
                $code = if ($issue.rule -and $issue.rule.name) { [string]$issue.rule.name } else { '' }
                $msg = if ($issue.message) { [string]$issue.message } else { '' }
                $file = ''
                $line = 0
                $col = 0
                if ($issue.range) {
                    if ($issue.range.filename) { $file = [string]$issue.range.filename }
                    if ($issue.range.start) {
                        if ($issue.range.start.line) { $line = [int]$issue.range.start.line }
                        if ($issue.range.start.column) { $col = [int]$issue.range.start.column }
                    }
                }
                $issues.Add([pscustomobject][ordered]@{
                        File     = $file
                        Line     = $line
                        Column   = $col
                        Severity = $sev.ToLowerInvariant()
                        Code     = $code
                        Message  = $msg
                    })
            }
        }
    }

    $status = if ($issues | Where-Object { $_.Severity -eq 'error' }) { 'fail' } else { 'pass' }

    return [pscustomobject][ordered]@{
        Engine         = 'terraform'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        Status         = $status
        FilesProcessed = $files.Count
        Issues         = $issues.ToArray()
    }
}
