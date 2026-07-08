function Invoke-AvmTerraformTestSuite {
    <#
    .SYNOPSIS
        Run 'terraform test' for a single tier (unit or integration) against
        the resolved module root.

    .DESCRIPTION
        Engine implementation shared by Invoke-AvmTestUnit and
        Invoke-AvmTestIntegration. Resolves the 'terraform' binary via
        Resolve-AvmTool, then:

          1. Enumerates '*.tftest.hcl' files under tests/<tier>/. If none
             exist, returns a pass envelope with FilesProcessed = 0 without
             invoking terraform - a module may legitimately ship only one
             tier.
          2. If the module root has no '.terraform/' directory and -NoInit
             was not passed, runs
                 terraform init -backend=false -upgrade=false -input=false
             so 'terraform test' can install provider schemas without real
             backend credentials.
          3. Runs
                 terraform test -test-directory=tests/<tier> -no-color -json
             against the working directory.
          4. Parses the newline-delimited JSON stream into the shared Issue
             shape: failing 'test_run' entries and error-level 'diagnostic'
             entries.

        Pass/fail is driven by the terraform exit code (0 = every run passed,
        1 = one or more failing/errored runs). Any other exit code is a
        terraform-internal failure and is rethrown as AvmProcessException.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER Tier
        Which test tier to run: 'unit' or 'integration'. Selects the
        tests/<tier>/ directory passed to -test-directory.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .PARAMETER NoInit
        Skip the implicit 'terraform init' even when '.terraform/' is
        missing. Use when init is genuinely impossible (offline + no cached
        providers) or when the caller has already run it.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [Parameter(Mandatory)]
        [ValidateSet('unit', 'integration')]
        [string] $Tier,

        [switch] $AllowPathFallback,

        [switch] $NoInit
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformTestSuite requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback

    $tierDir = Join-Path $Context.Root (Join-Path 'tests' $Tier)
    $tftestFiles = @()
    if (Test-Path -LiteralPath $tierDir) {
        $tftestFiles = @(
            Get-ChildItem -LiteralPath $tierDir -Recurse -File -Filter '*.tftest.hcl' -ErrorAction SilentlyContinue
        )
    }

    # A module may ship only one tier. No test files -> nothing to run; report
    # a clean pass so callers can treat "tier absent" the same as "tier green".
    if ($tftestFiles.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Engine         = 'terraform'
            Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
            ToolPath       = $tool.Path
            ToolSource     = $tool.Source
            Status         = 'pass'
            FilesProcessed = 0
            Issues         = @()
        }
    }

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

    # terraform accepts forward slashes in -test-directory on every platform.
    $testDir = ('tests/{0}' -f $Tier)
    $result = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList @('test', ('-test-directory={0}' -f $testDir), '-no-color', '-json') `
        -WorkingDirectory $Context.Root `
        -IgnoreExitCode

    # terraform test exit codes: 0 = all runs passed, 1 = one or more failing
    # or errored runs. Anything else is a terraform-internal failure -> rethrow.
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 1) {
        $stderr = if ($result.StdErr) { $result.StdErr.Trim() } else { '' }
        $tail = if ($stderr) { ": $stderr" } else { '.' }
        throw [AvmProcessException]::new(
            ('terraform test exited with code {0}{1}' -f $result.ExitCode, $tail))
    }

    $issues = New-Object System.Collections.Generic.List[object]
    $payload = if ($result.StdOut) { $result.StdOut } else { '' }
    foreach ($rawLine in ($payload -split "`n")) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }
        if (-not $line.StartsWith('{')) { continue }

        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue  # tolerate any non-JSON noise interleaved on the stream
        }

        $type = if ($obj.PSObject.Properties.Name -contains 'type') { [string]$obj.type } else { '' }

        if ($type -eq 'test_run' -and ($obj.PSObject.Properties.Name -contains 'test_run') -and $obj.test_run) {
            $run = $obj.test_run
            $runStatus = if ($run.PSObject.Properties.Name -contains 'status' -and $run.status) { [string]$run.status } else { '' }
            if ($runStatus.ToLowerInvariant() -in @('fail', 'error')) {
                $file = if ($run.PSObject.Properties.Name -contains 'path' -and $run.path) { [string]$run.path } else { $testDir }
                $runName = if ($run.PSObject.Properties.Name -contains 'run' -and $run.run) { [string]$run.run } else { '' }
                $msg = if ($runName) { ("test run '{0}' {1}" -f $runName, $runStatus) } else { ('test run {0}' -f $runStatus) }
                $issues.Add([pscustomobject][ordered]@{
                        File     = $file
                        Line     = 0
                        Column   = 0
                        Severity = 'error'
                        Code     = ''
                        Message  = $msg
                    })
            }
            continue
        }

        if ($type -eq 'diagnostic' -and ($obj.PSObject.Properties.Name -contains 'diagnostic') -and $obj.diagnostic) {
            $diag = $obj.diagnostic
            $sev = if ($diag.PSObject.Properties.Name -contains 'severity' -and $diag.severity) { [string]$diag.severity } else { 'error' }
            if ($sev.ToLowerInvariant() -ne 'error') { continue }
            $summary = if ($diag.PSObject.Properties.Name -contains 'summary' -and $diag.summary) { [string]$diag.summary } else { '' }
            $detail = if ($diag.PSObject.Properties.Name -contains 'detail' -and $diag.detail) { [string]$diag.detail } else { '' }
            $msg = if ($detail) { "$summary - $detail" } else { $summary }
            $file = ''
            $lineNo = 0
            $col = 0
            if (($diag.PSObject.Properties.Name -contains 'range') -and $diag.range) {
                if ($diag.range.PSObject.Properties.Name -contains 'filename' -and $diag.range.filename) {
                    $file = [string]$diag.range.filename
                }
                if (($diag.range.PSObject.Properties.Name -contains 'start') -and $diag.range.start) {
                    if ($diag.range.start.PSObject.Properties.Name -contains 'line' -and $diag.range.start.line) {
                        $lineNo = [int]$diag.range.start.line
                    }
                    if ($diag.range.start.PSObject.Properties.Name -contains 'column' -and $diag.range.start.column) {
                        $col = [int]$diag.range.start.column
                    }
                }
            }
            $issues.Add([pscustomobject][ordered]@{
                    File     = $file
                    Line     = $lineNo
                    Column   = $col
                    Severity = 'error'
                    Code     = ''
                    Message  = $msg
                })
            continue
        }
    }

    $status = if ($result.ExitCode -eq 0) { 'pass' } else { 'fail' }

    return [pscustomobject][ordered]@{
        Engine         = 'terraform'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        Status         = $status
        FilesProcessed = $tftestFiles.Count
        Issues         = $issues.ToArray()
    }
}
