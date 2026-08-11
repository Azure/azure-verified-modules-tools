function Resolve-AvmTflintConfigDir {
    <#
    .SYNOPSIS
        Resolve the directory holding the vendored AVM tflint configs.

    .DESCRIPTION
        Returns the absolute path to the directory that ships the three AVM
        tflint rulesets ('avm.tflint.hcl', 'avm.tflint_module.hcl',
        'avm.tflint_example.hcl'). Resolution order:

          1. $env:AVM_TFLINT_CONFIG_DIR - explicit override (test injection and
             power users pointing at a locally-checked-out governance copy).
          2. <ModuleRoot>/Resources/tflint - the configs vendored inside the
             module, kept byte-for-byte in sync with the governance
             tflint-configs/ folder.

        The chosen candidate must be a directory containing all three files.
        Throws AvmConfigurationException when none resolve, so the lint engine
        surfaces a clear package-integrity error rather than linting with no
        AVM rules.

    .OUTPUTS
        [string] absolute path to the resolved config directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $required = @('avm.tflint.hcl', 'avm.tflint_module.hcl', 'avm.tflint_example.hcl')

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:AVM_TFLINT_CONFIG_DIR) {
        $candidates.Add($env:AVM_TFLINT_CONFIG_DIR)
    }
    $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $candidates.Add((Join-Path $moduleRoot (Join-Path 'Resources' 'tflint')))

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        $present = $true
        foreach ($file in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $candidate $file) -PathType Leaf)) {
                $present = $false
                break
            }
        }
        if ($present) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }

    throw [AvmConfigurationException]::new(
        ("Cannot resolve the AVM tflint config bundle (looked in: {0}). " -f ($candidates -join '; ')) +
        'Set the AVM_TFLINT_CONFIG_DIR environment variable or reinstall Avm.Authoring so Resources/tflint is present.')
}

function Get-AvmTflintScope {
    <#
    .SYNOPSIS
        Build the ordered list of directories tflint should lint, each paired
        with the AVM ruleset that applies to it.

    .DESCRIPTION
        The AVM tflint rulesets are directory-specific: the repository root and
        every nested module use the strict rulesets, while examples use a
        relaxed ruleset (interface/docs rules disabled). A single recursive
        tflint invocation cannot express that, so the lint engine runs tflint
        once per scope with the matching '--config'.

        Scope order (deterministic):
          1. the repository root         -> avm.tflint.hcl
          2. each direct modules/*  dir  -> avm.tflint_module.hcl  (sorted by name)
          3. each direct examples/* dir  -> avm.tflint_example.hcl (sorted by name)

        modules/ and examples/ are enumerated one level deep (matching the
        governance 'foreachdirectory depth:1' behaviour) and skipped entirely
        when absent.

    .PARAMETER Root
        The Terraform repository root.

    .PARAMETER ConfigDir
        The directory returned by Resolve-AvmTflintConfigDir.

    .OUTPUTS
        [object[]] of hashtables with keys Dir (absolute), Config (absolute),
        Label, and RelPath ('.' for the root).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $ConfigDir
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath
    $scopes = New-Object System.Collections.Generic.List[object]

    $scopes.Add(@{
            Dir     = $rootFull
            Config  = (Join-Path $ConfigDir 'avm.tflint.hcl')
            Label   = 'root'
            RelPath = '.'
        })

    $groups = @(
        @{ Name = 'modules'; Config = 'avm.tflint_module.hcl' }
        @{ Name = 'examples'; Config = 'avm.tflint_example.hcl' }
    )
    foreach ($group in $groups) {
        $groupDir = Join-Path $rootFull $group.Name
        if (-not (Test-Path -LiteralPath $groupDir -PathType Container)) { continue }
        $children = @(Get-ChildItem -LiteralPath $groupDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($child in $children) {
            $scopes.Add(@{
                    Dir     = $child.FullName
                    Config  = (Join-Path $ConfigDir $group.Config)
                    Label   = ('{0}/{1}' -f $group.Name, $child.Name)
                    RelPath = ('{0}/{1}' -f $group.Name, $child.Name)
                })
        }
    }

    return $scopes.ToArray()
}

function Invoke-AvmTerraformLint {
    <#
    .SYNOPSIS
        Run the AVM tflint rulesets against a Terraform repository, one scope
        at a time, and fail on warnings by default.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmLint when the module context
        is Ecosystem='terraform'. Resolves 'tflint' via Resolve-AvmTool and the
        vendored AVM rulesets via Resolve-AvmTflintConfigDir. Repository-root
        avm.tflint.override.hcl, avm.tflint_example.override.hcl, and
        avm.tflint_module.override.hcl files are merged over those immutable
        bases in an isolated cache directory. The repository is copied to a
        clean temporary tree before every scope produced by Get-AvmTflintScope
        is evaluated:

            terraform init -input=false
            tflint --init   --config <absolute ruleset>          (install plugins)
            tflint --config <absolute ruleset> --format=json \
                   --minimum-failure-severity=<threshold>        (lint)

        This mirrors the legacy Terraform governance pre-check flow,
        including its repository-root override lookup and override-first
        attribute precedence. Example scopes reject tflint-pre.sh and run
        tflint-pre.ps1, when present, after Terraform initialization and before
        TFLint starts. Generated Terraform state remains confined to the
        temporary tree. A single recursive invocation with no '--config' (the
        previous behaviour) applied none of the AVM rules and could not express
        the per-directory rulesets.

        The failure threshold defaults to 'warning', so any warning-severity
        rule fails the gauntlet - most built-in tflint rules are warnings, so an
        'error'-only threshold reported false confidence. The threshold is
        passed to tflint (via --minimum-failure-severity, driving its exit code)
        and used to compute Status from the parsed issues, so both agree. All
        issues are still parsed and returned for reporting regardless of the
        threshold.

        tflint exit codes for the lint call:
          0  - no issues at or above the threshold
          2  - issues found (parsed; drives Status via the threshold)
          other - tflint itself failed (throws AvmProcessException)

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .PARAMETER MinimumFailureSeverity
        The lowest tflint severity that fails the run. One of 'error',
        'warning' (default), or 'notice'.

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

        [ValidateSet('error', 'warning', 'notice')]
        [string] $MinimumFailureSeverity = 'warning'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformLint requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $shellHooks = @(Get-ChildItem `
            -LiteralPath (Join-Path $Context.Root 'examples') `
            -Filter 'tflint-pre.sh' `
            -File `
            -Depth 1 `
            -ErrorAction SilentlyContinue |
            ForEach-Object { [System.IO.Path]::GetRelativePath($Context.Root, $_.FullName).Replace('\', '/') })
    if ($shellHooks.Count -gt 0) {
        throw [AvmConfigurationException]::new(
            ("The terraform lint engine runs PowerShell hooks only. Refactor these shell hooks to '.ps1': {0}" -f ($shellHooks -join ', ')))
    }

    $tool = Resolve-AvmTool -Name 'tflint' -AllowPathFallback:$AllowPathFallback
    $terraform = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback
    $baseConfigDir = Resolve-AvmTflintConfigDir
    $configSet = New-AvmTflintConfigSet -Root $Context.Root -BaseConfigDir $baseConfigDir
    $stageParent = Join-Path (Get-AvmFolder -Kind Cache) 'lint-stage'
    $stageRoot = Join-Path $stageParent ('avm-lint-' + [guid]::NewGuid().ToString('N'))

    # Severities at or above the threshold fail the run. tflint emits lowercase
    # 'error' / 'warning' / 'notice'.
    $failSeverities = switch ($MinimumFailureSeverity) {
        'error' { @('error') }
        'warning' { @('error', 'warning') }
        'notice' { @('error', 'warning', 'notice') }
    }

    $issues = New-Object System.Collections.Generic.List[object]
    $filesProcessed = 0
    $streamOutput = Test-AvmVerboseEnabled

    try {
        Write-AvmLog ("lint: staging terraform module at {0}" -f $stageRoot) -Level Verbose | Out-Null
        Copy-AvmTerraformModuleTree -SourceRoot $Context.Root -DestinationRoot $stageRoot
        $scopes = Get-AvmTflintScope -Root $stageRoot -ConfigDir $configSet.ConfigDir
        Write-AvmLog ("lint: discovered {0} terraform scope(s); failure threshold = {1}" -f $scopes.Count, $MinimumFailureSeverity) -Level Info | Out-Null

        $scopeIndex = 0
        foreach ($scope in $scopes) {
            $scopeIndex++
            Write-AvmLog ("lint: scope {0}/{1} = {2}" -f $scopeIndex, $scopes.Count, $scope.Label) -Level Info | Out-Null
            Write-AvmLog ("lint: scope directory = {0}; config = {1}" -f $scope.Dir, $scope.Config) -Level Verbose | Out-Null
            # Count only the top-level '*.tf' in this scope - tflint is invoked
            # non-recursively per scope, and nested modules/examples are their own
            # scopes, so this does not double-count.
            $filesProcessed += @(Get-ChildItem -LiteralPath $scope.Dir -File -Filter '*.tf' -ErrorAction SilentlyContinue).Count

            $null = Invoke-AvmProcess `
                -FilePath $terraform.Path `
                -ArgumentList @('init', '-input=false') `
                -WorkingDirectory $scope.Dir `
                -Label ('{0}: terraform init' -f $scope.Label) `
                -StreamOutput:$streamOutput

            if ($scope.Label -like 'examples/*') {
                Invoke-AvmScriptHook `
                    -HookPath (Join-Path $scope.Dir 'tflint-pre.ps1') `
                    -WorkingDirectory $scope.Dir `
                    -Label ('{0}: tflint-pre.ps1' -f $scope.Label)
            }

            # Install the plugins the ruleset declares (terraform + avm). Idempotent
            # and cached under the shared tflint plugin dir, so repeat scopes are
            # cheap. A non-zero exit here means plugin acquisition failed outright.
            $init = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--init', '--config', $scope.Config) `
                -WorkingDirectory $scope.Dir `
                -IgnoreExitCode `
                -StreamOutput:$streamOutput `
                -Label ('{0}: tflint init' -f $scope.Label)
            if ($init.ExitCode -ne 0) {
                $stderr = if ($init.StdErr) { $init.StdErr.Trim() } else { '' }
                $tail = if ($stderr) { ": $stderr" } else { '.' }
                throw [AvmProcessException]::new(
                    ("tflint --init for scope '{0}' exited with code {1}{2}" -f $scope.Label, $init.ExitCode, $tail))
            }

            $lintArgs = @(
                '--config', $scope.Config,
                '--format=json',
                ('--minimum-failure-severity={0}' -f $MinimumFailureSeverity)
            )

            $run = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList $lintArgs `
                -WorkingDirectory $scope.Dir `
                -IgnoreExitCode `
                -StreamOutput:$streamOutput `
                -Label ('{0}: tflint' -f $scope.Label)

            # exit 0 = clean; 2 = issues found; anything else = tflint misbehaved.
            if ($run.ExitCode -ne 0 -and $run.ExitCode -ne 2) {
                $stderr = if ($run.StdErr) { $run.StdErr.Trim() } else { '' }
                $tail = if ($stderr) { ": $stderr" } else { '.' }
                throw [AvmProcessException]::new(
                    ("tflint for scope '{0}' exited with code {1}{2}" -f $scope.Label, $run.ExitCode, $tail))
            }

            $payload = if ($run.StdOut) { $run.StdOut.Trim() } else { '' }
            if (-not $payload) { continue }

            try {
                $parsed = $payload | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                throw [AvmProcessException]::new(
                    ("Could not parse tflint --format=json output for scope '{0}': {1}" -f $scope.Label, $_.Exception.Message))
            }

            if (-not ($parsed -and ($parsed.PSObject.Properties.Name -contains 'issues'))) { continue }

            foreach ($issue in @($parsed.issues)) {
                $sev = if ($issue.rule -and $issue.rule.severity) { ([string]$issue.rule.severity).ToLowerInvariant() } else { 'warning' }
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
                # Tag the file with its scope so root/module/example issues are
                # distinguishable; tflint reports filenames relative to its own
                # working directory.
                if ($scope.RelPath -ne '.' -and $file) {
                    $file = ('{0}/{1}' -f $scope.RelPath, $file)
                }
                $file = $file -replace '\\', '/'

                $issues.Add([pscustomobject][ordered]@{
                        File     = $file
                        Line     = $line
                        Column   = $col
                        Severity = $sev
                        Code     = $code
                        Message  = $msg
                        Scope    = $scope.Label
                    })
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($configSet.StageDir -and (Test-Path -LiteralPath $configSet.StageDir)) {
            Remove-Item -LiteralPath $configSet.StageDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $status = if ($issues | Where-Object { $failSeverities -contains $_.Severity }) { 'fail' } else { 'pass' }
    Write-AvmLog ("lint: terraform completed with {0} issue(s) across {1} file(s)" -f $issues.Count, $filesProcessed) -Level Verbose | Out-Null

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
