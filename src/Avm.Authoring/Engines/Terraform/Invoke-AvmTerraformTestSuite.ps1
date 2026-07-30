function Invoke-AvmTerraformTestSuite {
    <#
    .SYNOPSIS
        Run 'terraform test' for a single tier (unit or integration) against
        the resolved module root.

    .DESCRIPTION
        Engine implementation shared by Invoke-AvmTestUnit and
        Invoke-AvmTestIntegration. Resolves the 'terraform' binary via
        Resolve-AvmTool, then:

          1. Enumerates test targets: the module root plus each immediate
             'modules/*' subdirectory. A target is runnable when it ships at
             least one '*.tftest.hcl' under tests/<tier>/. If no target is
             runnable, returns a pass envelope with FilesProcessed = 0 without
             invoking terraform.
          2. Rejects shell hooks fail-fast: any tests/<tier>/setup.sh or
             teardown.sh throws AvmConfigurationException before terraform runs
             (this engine is PowerShell-only).
          3. Per runnable target (cwd = target root): runs an optional
             tests/<tier>/setup.ps1 hook in an isolated pwsh subprocess; a
             failing hook records an issue and skips that target. Then, if the
             target has no '.terraform/' and -NoInit was not passed, runs
                 terraform init -backend=false -upgrade=false -input=false
             followed by
                 terraform test -test-directory=tests/<tier> -no-color -json
          4. Parses each target's newline-delimited JSON stream into the shared
             Issue shape (failing 'test_run' entries and error-level
             'diagnostic' entries), prefixing submodule paths with
             'modules/<name>/'.

        Status is 'fail' when any target reports a failing/errored run or a
        setup.ps1 hook fails; otherwise 'pass'. A terraform init failure or an
        unexpected 'terraform test' exit code is rethrown as AvmProcessException.

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

    $targets = @(Get-AvmTerraformTestTarget -Root $Context.Root -Tier $Tier)

    if ($targets.Count -eq 0) {
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

    $shHooks = New-Object System.Collections.Generic.List[string]
    foreach ($target in $targets) {
        $relPrefix = if ($target.Rel) { $target.Rel + '/' } else { '' }
        foreach ($shName in @('setup.sh', 'teardown.sh')) {
            $shPath = Join-Path $target.Path (Join-Path 'tests' (Join-Path $Tier $shName))
            if (Test-Path -LiteralPath $shPath -PathType Leaf) {
                $shHooks.Add(('{0}tests/{1}/{2}' -f $relPrefix, $Tier, $shName))
            }
        }
    }
    if ($shHooks.Count -gt 0) {
        throw [AvmConfigurationException]::new(
            ("The terraform {0} test engine runs PowerShell setup hooks only; convert these shell hooks to '.ps1': {1}" -f $Tier, ($shHooks -join ', ')))
    }

    $pwshPath = [Environment]::ProcessPath
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        $pwshCmd = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { 'pwsh' }
    }

    # terraform accepts forward slashes in -test-directory on every platform.
    $testDir = ('tests/{0}' -f $Tier)
    $issues = New-Object System.Collections.Generic.List[object]
    $filesProcessed = 0
    $anyFail = $false

    foreach ($target in $targets) {
        $targetDir = $target.Path
        $relPrefix = if ($target.Rel) { $target.Rel + '/' } else { '' }
        $filesProcessed += $target.Files.Count

        $setup = Invoke-AvmTerraformSetupHook `
            -PwshPath $pwshPath `
            -HookPath (Join-Path $targetDir (Join-Path 'tests' (Join-Path $Tier 'setup.ps1'))) `
            -WorkingDirectory $targetDir
        if ($null -ne $setup -and $setup.ExitCode -ne 0) {
            $detail = if ($setup.StdErr) { $setup.StdErr.Trim() } elseif ($setup.StdOut) { $setup.StdOut.Trim() } else { '' }
            $issues.Add([pscustomobject][ordered]@{
                    File     = ('{0}{1}/setup.ps1' -f $relPrefix, $testDir)
                    Line     = 0
                    Column   = 0
                    Severity = 'error'
                    Code     = ''
                    Message  = ('setup.ps1 hook failed (exit {0}): {1}' -f $setup.ExitCode, $detail)
                })
            $anyFail = $true
            continue
        }

        $envVars = ConvertFrom-AvmDotEnv -Path (Join-Path $targetDir '.env')

        $terraformDir = Join-Path $targetDir '.terraform'
        if (-not $NoInit -and -not (Test-Path -LiteralPath $terraformDir)) {
            $initResult = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('init', '-backend=false', '-upgrade=false', '-input=false', '-no-color') `
                -WorkingDirectory $targetDir `
                -EnvVars $envVars `
                -IgnoreExitCode

            if ($initResult.ExitCode -ne 0) {
                $detail = if ($initResult.StdErr) { $initResult.StdErr.Trim() } else { $initResult.StdOut.Trim() }
                throw [AvmProcessException]::new(
                    ('terraform init failed with exit code {0}: {1}' -f $initResult.ExitCode, $detail))
            }
        }

        $result = Invoke-AvmProcess `
            -FilePath $tool.Path `
            -ArgumentList @('test', ('-test-directory={0}' -f $testDir), '-no-color', '-json') `
            -WorkingDirectory $targetDir `
            -EnvVars $envVars `
            -IgnoreExitCode

        # terraform test exit codes: 0 = all runs passed, 1 = one or more failing
        # or errored runs. Anything else is a terraform-internal failure -> rethrow.
        if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 1) {
            $stderr = if ($result.StdErr) { $result.StdErr.Trim() } else { '' }
            $tail = if ($stderr) { ": $stderr" } else { '.' }
            throw [AvmProcessException]::new(
                ('terraform test exited with code {0}{1}' -f $result.ExitCode, $tail))
        }
        if ($result.ExitCode -ne 0) { $anyFail = $true }

        foreach ($issue in (ConvertFrom-AvmTerraformTestJson -Payload ([string]$result.StdOut) -TestDir $testDir -RelPrefix $relPrefix)) {
            $issues.Add($issue)
        }
    }

    $status = if ($anyFail) { 'fail' } else { 'pass' }

    return [pscustomobject][ordered]@{
        Engine         = 'terraform'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        Status         = $status
        FilesProcessed = $filesProcessed
        Issues         = $issues.ToArray()
    }
}

function Get-AvmTerraformTestTarget {
    <#
        .SYNOPSIS
            Enumerates runnable terraform test targets: the module root plus each
            immediate 'modules/*' subdirectory that ships at least one
            tests/<Tier>/*.tftest.hcl file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $Tier
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $candidates = New-Object System.Collections.Generic.List[object]
    $candidates.Add([pscustomobject]@{ Path = $Root; Rel = '' })

    $modulesDir = Join-Path $Root 'modules'
    if (Test-Path -LiteralPath $modulesDir -PathType Container) {
        $subModules = Get-ChildItem -LiteralPath $modulesDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property Name
        foreach ($sub in $subModules) {
            $candidates.Add([pscustomobject]@{ Path = $sub.FullName; Rel = ('modules/{0}' -f $sub.Name) })
        }
    }

    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $candidates) {
        $tierDir = Join-Path $candidate.Path (Join-Path 'tests' $Tier)
        if (-not (Test-Path -LiteralPath $tierDir -PathType Container)) { continue }
        $files = @(
            Get-ChildItem -LiteralPath $tierDir -Recurse -File -Filter '*.tftest.hcl' -ErrorAction SilentlyContinue
        )
        if ($files.Count -eq 0) { continue }
        $targets.Add([pscustomobject]@{
                Path  = $candidate.Path
                Rel   = $candidate.Rel
                Files = $files
            })
    }

    return $targets.ToArray()
}

function Invoke-AvmTerraformSetupHook {
    <#
        .SYNOPSIS
            Runs an optional setup.ps1 hook in an isolated pwsh subprocess.
            Returns $null when the hook is absent, otherwise the process result.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $PwshPath,

        [Parameter(Mandatory)]
        [string] $HookPath,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $HookPath -PathType Leaf)) {
        return $null
    }

    return Invoke-AvmProcess `
        -FilePath $PwshPath `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $HookPath) `
        -WorkingDirectory $WorkingDirectory `
        -IgnoreExitCode
}

function ConvertFrom-AvmTerraformTestJson {
    <#
        .SYNOPSIS
            Parses the newline-delimited JSON stream from 'terraform test -json'
            into the shared Issue shape. Submodule file paths are prefixed with
            RelPrefix (e.g. 'modules/<name>/').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Payload,

        [Parameter(Mandatory)]
        [string] $TestDir,

        [Parameter()]
        [string] $RelPrefix = ''
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Payload)) { return $issues.ToArray() }

    foreach ($rawLine in ($Payload -split "`n")) {
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
                $file = if ($run.PSObject.Properties.Name -contains 'path' -and $run.path) { [string]$run.path } else { $TestDir }
                $runName = if ($run.PSObject.Properties.Name -contains 'run' -and $run.run) { [string]$run.run } else { '' }
                $msg = if ($runName) { ("test run '{0}' {1}" -f $runName, $runStatus) } else { ('test run {0}' -f $runStatus) }
                $issues.Add([pscustomobject][ordered]@{
                        File     = ('{0}{1}' -f $RelPrefix, $file)
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
            $prefixed = if ($file) { '{0}{1}' -f $RelPrefix, $file } else { '' }
            $issues.Add([pscustomobject][ordered]@{
                    File     = $prefixed
                    Line     = $lineNo
                    Column   = $col
                    Severity = 'error'
                    Code     = ''
                    Message  = $msg
                })
            continue
        }
    }

    return $issues.ToArray()
}
