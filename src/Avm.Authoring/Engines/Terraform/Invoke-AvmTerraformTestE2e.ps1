function Invoke-AvmTerraformTestE2e {
    <#
    .SYNOPSIS
        Run the terraform end-to-end (e2e) test tier by provisioning, checking
        idempotency, and destroying each example under examples/.

    .DESCRIPTION
        Engine implementation behind Invoke-AvmTestE2e. Unlike the unit and
        integration tiers (which run 'terraform test' against tests/<tier>/),
        the e2e tier exercises the module's *examples* against a real backend:
        it deploys real infrastructure and tears it back down.

        Resolves the 'terraform' binary via Resolve-AvmTool, then:

          1. Enumerates immediate subdirectories of examples/ that contain at
             least one '*.tf' file. Directories carrying a '.e2eignore' marker
             file are skipped. If no runnable example exists, returns a pass
             envelope with FilesProcessed = 0 without invoking terraform.
          2. Before provisioning, scans every runnable example for a legacy
             shell hook (pre.sh / post.sh). This engine runs PowerShell hooks
             only, so if any '.sh' hook is found it throws an
             AvmConfigurationException naming the offending files and asking
             the author to port them to '.ps1' - fail-fast, before any real
             infrastructure is created.
          3. For each example, in its own working directory:
               a. pre.ps1 hook (if present): run in an isolated 'pwsh -File'
                  subprocess. Isolation means a hook that exports secrets, sets
                  environment variables, or calls 'exit' cannot corrupt the
                  runner or leak into the next example. The hook's convention is
                  to write any secrets terraform needs as KEY=VALUE lines into a
                  '.env' file. A non-zero hook exit is recorded as an Issue and
                  the terraform steps for that example are skipped (its post.ps1
                  still runs).
               b. .env sourcing: after pre.ps1, a '.env' file next to the
                  example (if present) is parsed and its values are passed to
                  every terraform subprocess below via -EnvVars.
               c. terraform init -input=false -no-color
                  (a REAL backend init - e2e provisions real resources, so this
                  is NOT the '-backend=false' init the test tiers use).
               d. terraform apply -auto-approve -input=false -no-color, with
                  up to -MaxRetry retries on a transient failure. e2e deploys
                  real infrastructure, so an apply fails intermittently on
                  region/SKU capacity rather than on a module defect. When the
                  combined apply output matches the capacity/quota patterns in
                  Test-AvmTerraformTransientError, the example is destroyed and
                  redeployed. Destroying first is required, not cosmetic:
                  example names come from module.naming and do not depend on
                  the region, so re-planning in place would replace the
                  resource group under the same name while name-only dependents
                  (subnets, for example) are planned as unchanged - Azure
                  cascade-deletes those and the apply fails with 'Root object
                  was present, but now absent'. Destroying also drops
                  random_integer.region_index from state, so the next plan
                  re-rolls the region by itself. A retry that fails to destroy
                  aborts rather than deploying over partial state. Each retry
                  records a warning-level Issue, so a recovered example stays
                  green but the flake is still visible.
               e. idempotency: terraform plan -detailed-exitcode -input=false
                  -no-color. Exit 2 means the second plan still reports pending
                  changes (the module is not idempotent) and is recorded as a
                  failure. Never retried: retrying would hide a module that is
                  genuinely not idempotent.
               f. terraform destroy -auto-approve -input=false -no-color. Run
                  whenever init succeeded - including after a failed apply - so
                  a broken run does not leak real Azure resources.
               g. post.ps1 hook (if present): run in an isolated 'pwsh -File'
                  subprocess. Always runs - after a pre-hook failure, an init
                  failure, or a clean pass - so teardown/cleanup happens on
                  every path. A non-zero exit is recorded as an Issue.

        Every terraform or hook failure is captured as an Issue; the aggregate
        Status is 'fail' if any example produced an error-level Issue, otherwise
        'pass'. Warning-level Issues (a recovered transient apply, for example)
        are reported without failing the run. FilesProcessed counts the examples
        that were processed.

        e2e provisions and destroys real cloud resources, so it needs valid
        credentials at runtime (an authenticated 'az' session or ARM_*
        environment variables). Authentication is left to terraform and its
        providers; this engine performs no preflight.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .PARAMETER MaxRetry
        How many times to retry an example whose 'terraform apply' failed with
        a transient capacity/quota error. Defaults to 2 (up to three attempts
        in total). 0 disables retries.

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

        [ValidateRange(0, 10)]
        [int] $MaxRetry = 2
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformTestE2e requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback

    $examplesRoot = Join-Path $Context.Root 'examples'
    $exampleDirs = @()
    if (Test-Path -LiteralPath $examplesRoot) {
        $exampleDirs = @(
            Get-ChildItem -LiteralPath $examplesRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object -Property Name |
                Where-Object {
                    $hasTf = @(Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.tf' -ErrorAction SilentlyContinue).Count -gt 0
                    $ignored = Test-Path -LiteralPath (Join-Path $_.FullName '.e2eignore')
                    $hasTf -and -not $ignored
                }
        )
    }

    # A module may ship no examples (or only ignored ones). Nothing to run ->
    # report a clean pass so callers treat "no examples" the same as "green".
    if ($exampleDirs.Count -eq 0) {
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

    # This engine runs PowerShell hooks only. A legacy shell hook (pre.sh /
    # post.sh) needs bash - absent on stock Windows - and would otherwise be
    # silently ignored, so reject it fail-fast, BEFORE we provision any real
    # infrastructure, and tell the author to port it to '.ps1'. Only runnable
    # (non-ignored) examples are scanned; an ignored example's hooks never run.
    $shHooks = New-Object System.Collections.Generic.List[string]
    foreach ($example in $exampleDirs) {
        foreach ($shName in @('pre.sh', 'post.sh')) {
            if (Test-Path -LiteralPath (Join-Path $example.FullName $shName) -PathType Leaf) {
                $shHooks.Add(('examples/{0}/{1}' -f $example.Name, $shName))
            }
        }
    }
    if ($shHooks.Count -gt 0) {
        throw [AvmConfigurationException]::new(
            ("The terraform e2e engine runs PowerShell hooks only; convert these shell hooks to '.ps1': {0}" -f ($shHooks -join ', ')))
    }

    # Resolve the running pwsh once. Hooks execute as isolated 'pwsh -File'
    # subprocesses so a hook's 'exit', secrets, or environment changes cannot
    # corrupt the runner or bleed into the next example.
    $pwshPath = [Environment]::ProcessPath
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        $pwshCmd = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { 'pwsh' }
    }

    $issues = New-Object System.Collections.Generic.List[object]

    foreach ($example in $exampleDirs) {
        $exampleDir = $example.FullName
        $rel = ('examples/{0}' -f $example.Name)

        # 1. pre.ps1 hook (optional). Runs before terraform in its own pwsh
        #    subprocess; by convention it writes any secrets terraform needs
        #    into a '.env' file next to the example. A failing pre-hook skips
        #    the terraform steps (there is nothing safely provisioned to tear
        #    down) but the post-hook still runs below.
        $preOk = $true
        $preHook = Invoke-AvmE2eHook -PwshPath $pwshPath -HookPath (Join-Path $exampleDir 'pre.ps1') -WorkingDirectory $exampleDir
        if ($null -ne $preHook -and $preHook.ExitCode -ne 0) {
            $detail = if ($preHook.StdErr) { $preHook.StdErr.Trim() } elseif ($preHook.StdOut) { $preHook.StdOut.Trim() } else { '' }
            $issues.Add((New-AvmE2eIssue -File ('{0}/pre.ps1' -f $rel) -Message ('pre.ps1 hook failed (exit {0}): {1}' -f $preHook.ExitCode, $detail)))
            $preOk = $false
        }

        if ($preOk) {
            # 2. .env bridge - values written by pre.ps1 flow into every
            #    terraform subprocess below via -EnvVars (empty when absent).
            $envVars = ConvertFrom-AvmDotEnv -Path (Join-Path $exampleDir '.env')

            # 3. init against a real backend (e2e deploys real infrastructure).
            $init = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('init', '-input=false', '-no-color') `
                -WorkingDirectory $exampleDir `
                -EnvVars $envVars `
                -IgnoreExitCode

            if ($init.ExitCode -ne 0) {
                $detail = if ($init.StdErr) { $init.StdErr.Trim() } elseif ($init.StdOut) { $init.StdOut.Trim() } else { '' }
                $issues.Add((New-AvmE2eIssue -File $rel -Message ('terraform init failed (exit {0}): {1}' -f $init.ExitCode, $detail)))
                # Nothing was initialised, so there is nothing to destroy.
            }
            else {
                # 4. apply, retried on a transient capacity failure. Every
                #    retry destroys first: that drops random_integer.region_index
                #    from state so the next plan re-rolls the region, and it
                #    avoids replacing the resource group under a name-only
                #    dependent graph. See .DESCRIPTION for the full rationale.
                $applyArgs = @('apply', '-auto-approve', '-input=false', '-no-color')
                $destroyArgs = @('destroy', '-auto-approve', '-input=false', '-no-color')

                $attempt = 0
                $applyOk = $false
                $retryAborted = $false
                $apply = $null

                while ($true) {
                    $apply = Invoke-AvmProcess `
                        -FilePath $tool.Path `
                        -ArgumentList $applyArgs `
                        -WorkingDirectory $exampleDir `
                        -EnvVars $envVars `
                        -IgnoreExitCode

                    if ($apply.ExitCode -eq 0) {
                        $applyOk = $true
                        break
                    }

                    $combined = [string]$apply.StdOut + "`n" + [string]$apply.StdErr
                    if ($attempt -ge $MaxRetry -or -not (Test-AvmTerraformTransientError -Output $combined)) {
                        break
                    }

                    $attempt++

                    $retryDestroy = Invoke-AvmProcess `
                        -FilePath $tool.Path `
                        -ArgumentList $destroyArgs `
                        -WorkingDirectory $exampleDir `
                        -EnvVars $envVars `
                        -IgnoreExitCode

                    if ($retryDestroy.ExitCode -ne 0) {
                        $detail = if ($retryDestroy.StdErr) { $retryDestroy.StdErr.Trim() } elseif ($retryDestroy.StdOut) { $retryDestroy.StdOut.Trim() } else { '' }
                        $message = 'retry {0} aborted: terraform destroy failed (exit {1}), refusing to redeploy over partial state: {2}' -f $attempt, $retryDestroy.ExitCode, $detail
                        $issues.Add((New-AvmE2eIssue -File $rel -Message $message))
                        $retryAborted = $true
                        break
                    }

                    $message = 'terraform apply hit a transient capacity error (exit {0}); destroyed and retrying ({1} of {2}).' -f $apply.ExitCode, $attempt, $MaxRetry
                    $issues.Add((New-AvmE2eIssue -File $rel -Severity 'warning' -Message $message))
                }

                if (-not $applyOk -and -not $retryAborted) {
                    $detail = if ($apply.StdErr) { $apply.StdErr.Trim() } elseif ($apply.StdOut) { $apply.StdOut.Trim() } else { '' }
                    $exhausted = if ($attempt -gt 0) { (' after {0} retries' -f $attempt) } else { '' }
                    $message = 'terraform apply failed (exit {0}){1}: {2}' -f $apply.ExitCode, $exhausted, $detail
                    $issues.Add((New-AvmE2eIssue -File $rel -Message $message))
                }

                if ($applyOk) {
                    # 5. idempotency: a second plan must report no changes.
                    $plan = Invoke-AvmProcess `
                        -FilePath $tool.Path `
                        -ArgumentList @('plan', '-detailed-exitcode', '-input=false', '-no-color') `
                        -WorkingDirectory $exampleDir `
                        -EnvVars $envVars `
                        -IgnoreExitCode

                    # -detailed-exitcode: 0 = no changes, 2 = changes, 1 = error.
                    if ($plan.ExitCode -eq 2) {
                        $issues.Add((New-AvmE2eIssue -File $rel -Message 'idempotency check failed: a second plan reported pending changes (exit 2).'))
                    }
                    elseif ($plan.ExitCode -ne 0) {
                        $detail = if ($plan.StdErr) { $plan.StdErr.Trim() } elseif ($plan.StdOut) { $plan.StdOut.Trim() } else { '' }
                        $issues.Add((New-AvmE2eIssue -File $rel -Message ('idempotency plan errored (exit {0}): {1}' -f $plan.ExitCode, $detail)))
                    }
                }

                # 6. destroy - always attempt once init has succeeded, even
                #    after a failed apply or an aborted retry, so a broken run
                #    does not leak real Azure resources.
                $destroy = Invoke-AvmProcess `
                    -FilePath $tool.Path `
                    -ArgumentList @('destroy', '-auto-approve', '-input=false', '-no-color') `
                    -WorkingDirectory $exampleDir `
                    -EnvVars $envVars `
                    -IgnoreExitCode

                if ($destroy.ExitCode -ne 0) {
                    $detail = if ($destroy.StdErr) { $destroy.StdErr.Trim() } elseif ($destroy.StdOut) { $destroy.StdOut.Trim() } else { '' }
                    $issues.Add((New-AvmE2eIssue -File $rel -Message ('terraform destroy failed (exit {0}): {1}' -f $destroy.ExitCode, $detail)))
                }
            }
        }

        # 7. post.ps1 hook (optional). Always runs - after a pre-hook failure,
        #    an init failure, or a clean pass - so teardown/cleanup happens on
        #    every path.
        $postHook = Invoke-AvmE2eHook -PwshPath $pwshPath -HookPath (Join-Path $exampleDir 'post.ps1') -WorkingDirectory $exampleDir
        if ($null -ne $postHook -and $postHook.ExitCode -ne 0) {
            $detail = if ($postHook.StdErr) { $postHook.StdErr.Trim() } elseif ($postHook.StdOut) { $postHook.StdOut.Trim() } else { '' }
            $issues.Add((New-AvmE2eIssue -File ('{0}/post.ps1' -f $rel) -Message ('post.ps1 hook failed (exit {0}): {1}' -f $postHook.ExitCode, $detail)))
        }
    }

    $status = if ($issues | Where-Object { $_.Severity -eq 'error' }) { 'fail' } else { 'pass' }

    return [pscustomobject][ordered]@{
        Engine         = 'terraform'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        Status         = $status
        FilesProcessed = $exampleDirs.Count
        Issues         = $issues.ToArray()
    }
}

function New-AvmE2eIssue {
    <#
    .SYNOPSIS
        Build a shared-shape Issue object for the e2e engine.

    .DESCRIPTION
        Defaults to 'error' severity. Pass -Severity 'warning' for something
        worth reporting that must not fail the run, such as an apply that was
        recovered by a retry.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Factory function; returns a new pscustomobject and mutates no external state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $File,

        [Parameter(Mandatory)]
        [string] $Message,

        [ValidateSet('error', 'warning')]
        [string] $Severity = 'error'
    )

    [pscustomobject][ordered]@{
        File     = $File
        Line     = 0
        Column   = 0
        Severity = $Severity
        Code     = ''
        Message  = $Message
    }
}

function Test-AvmTerraformTransientError {
    <#
    .SYNOPSIS
        Decide whether terraform output describes a transient capacity failure
        that is worth retrying.

    .DESCRIPTION
        e2e deploys real infrastructure, so an apply fails intermittently on
        region and SKU capacity rather than on a module defect. The patterns
        below are matched case-insensitively against terraform's combined
        stdout+stderr and are deliberately anchored to capacity and quota
        wording.

        Broad Azure codes are excluded on purpose. 'OperationNotAllowed', for
        example, covers both quota exhaustion and 'cannot delete resource while
        nested resources exist'; only the former should ever be retried, and
        matching the code would mask the latter.

        $env:AVM_E2E_RETRY_PATTERN adds one further regex to the list. It is
        additive, never a replacement, so a module hitting a capacity error the
        built-in list does not know about can opt in without weakening the
        defaults.

    .PARAMETER Output
        Combined terraform output to classify.

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Output
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $false
    }

    $patterns = @(
        'SkuNotAvailable'
        'Capacity Restrictions'
        'is currently not available in location'
        'sku_selector found no deployable VM size'
        'Allocation ?Failed'
        'results in exceeding approved'
    )

    if (-not [string]::IsNullOrWhiteSpace($env:AVM_E2E_RETRY_PATTERN)) {
        $patterns += $env:AVM_E2E_RETRY_PATTERN
    }

    return [regex]::IsMatch(
        $Output,
        ($patterns -join '|'),
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Invoke-AvmE2eHook {
    <#
    .SYNOPSIS
        Run an optional per-example PowerShell hook in an isolated subprocess.

    .DESCRIPTION
        Returns $null when the hook file is absent (the common case), otherwise
        the Invoke-AvmProcess result object. The hook runs as
        'pwsh -NoProfile -NonInteractive -File <hook>' with the example as its
        working directory, so its exit code, secrets, and environment changes
        stay contained and cannot corrupt the runner or leak into the next
        example. Hooks deliberately do NOT receive terraform's -EnvVars; a hook
        author communicates with terraform through a '.env' file instead.
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

    if (-not (Test-Path -LiteralPath $HookPath -PathType Leaf)) {
        return $null
    }

    return Invoke-AvmProcess `
        -FilePath $PwshPath `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $HookPath) `
        -WorkingDirectory $WorkingDirectory `
        -IgnoreExitCode
}
