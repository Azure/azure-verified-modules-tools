function Invoke-AvmTerraformTest {
    <#
    .SYNOPSIS
        Run 'terraform validate -json' against the resolved module root.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmTest when the module
        context is Ecosystem='terraform'. Resolves the 'terraform' binary
        via Resolve-AvmTool, then:

          1. If the module root has no '.terraform/' directory and -NoInit
             was not passed, runs
                terraform init -backend=false -upgrade=false -input=false
             so 'validate' can resolve provider requirements without
             needing real backend credentials.
          2. Runs 'terraform validate -no-color -json' against the
             working directory.
          3. Parses the JSON 'diagnostics' array into the shared Issue
             shape used by other engines.

        Auto-init can be skipped with -NoInit; callers running inside a
        pre-initialised module (or who have already run 'terraform init'
        themselves) can pass that switch through Invoke-AvmTest.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .PARAMETER NoInit
        Skip the implicit 'terraform init' even when '.terraform/' is
        missing. Use when init is genuinely impossible (offline + no
        cached providers) or when the caller has already run it.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [switch] $NoInit
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformTest requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback

    $discovered = Get-ChildItem -LiteralPath $Context.Root -Recurse -File -Filter '*.tf' -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = [System.IO.Path]::GetRelativePath($Context.Root, $_.FullName)
            $parts = $rel -split '[\\/]'
            -not ($parts | Where-Object { $_.StartsWith('.') -or $_ -eq 'node_modules' })
        }
    $files = @($discovered)

    $terraformDir = Join-Path $Context.Root '.terraform'
    if (-not $NoInit -and -not (Test-Path -LiteralPath $terraformDir)) {
        $initResult = Invoke-AvmProcess `
            -FilePath $tool.Path `
            -ArgumentList @('init', '-backend=false', '-upgrade=false', '-input=false', '-no-color') `
            -WorkingDirectory $Context.Root `
            -IgnoreExitCode

        if ($initResult.ExitCode -ne 0) {
            $detail = if ($initResult.StdErr) { $initResult.StdErr.Trim() } else { $initResult.StdOut.Trim() }
            throw [AvmProcessException]::new(
                ('terraform init failed with exit code {0}: {1}' -f $initResult.ExitCode, $detail))
        }
    }

    $result = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList @('validate', '-no-color', '-json') `
        -WorkingDirectory $Context.Root `
        -IgnoreExitCode

    # terraform validate exit codes: 0 = no errors, 1 = errors / config invalid.
    # Anything else is a terraform-internal failure -> rethrow.
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 1) {
        $stderr = if ($result.StdErr) { $result.StdErr.Trim() } else { '' }
        $tail = if ($stderr) { ": $stderr" } else { '.' }
        throw [AvmProcessException]::new(
            ('terraform validate exited with code {0}{1}' -f $result.ExitCode, $tail))
    }

    $issues = New-Object System.Collections.Generic.List[object]
    $payload = if ($result.StdOut) { $result.StdOut.Trim() } else { '' }
    if ($payload) {
        try {
            $parsed = $payload | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw [AvmProcessException]::new(
                "Could not parse terraform validate -json output: $($_.Exception.Message)")
        }
        if ($parsed -and ($parsed.PSObject.Properties.Name -contains 'diagnostics')) {
            foreach ($diag in @($parsed.diagnostics)) {
                $sev = if ($diag.severity) { [string]$diag.severity } else { 'warning' }
                $summary = if ($diag.summary) { [string]$diag.summary } else { '' }
                $detail = if ($diag.detail) { [string]$diag.detail } else { '' }
                $msg = if ($detail) { "$summary - $detail" } else { $summary }
                $file = ''
                $line = 0
                $col = 0
                if ($diag.PSObject.Properties.Name -contains 'range' -and $diag.range) {
                    if ($diag.range.filename) { $file = [string]$diag.range.filename }
                    if ($diag.range.start) {
                        if ($diag.range.start.line) { $line = [int]$diag.range.start.line }
                        if ($diag.range.start.column) { $col = [int]$diag.range.start.column }
                    }
                }
                $issues.Add([pscustomobject][ordered]@{
                        File     = $file
                        Line     = $line
                        Column   = $col
                        Severity = $sev.ToLowerInvariant()
                        Code     = ''
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
