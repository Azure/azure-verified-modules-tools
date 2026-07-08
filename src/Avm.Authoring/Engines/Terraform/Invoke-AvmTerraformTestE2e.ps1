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
          2. For each example, in its own working directory:
               a. terraform init -input=false -no-color
                  (a REAL backend init - e2e provisions real resources, so this
                  is NOT the '-backend=false' init the test tiers use).
               b. terraform apply -auto-approve -input=false -no-color
               c. idempotency: terraform plan -detailed-exitcode -input=false
                  -no-color. Exit 2 means the second plan still reports pending
                  changes (the module is not idempotent) and is recorded as a
                  failure.
               d. terraform destroy -auto-approve -input=false -no-color. Run
                  whenever init succeeded - including after a failed apply - so
                  a broken run does not leak real Azure resources.

        Every terraform failure is captured as an Issue; the aggregate Status
        is 'fail' if any example produced an error-level Issue, otherwise
        'pass'. FilesProcessed counts the examples that were processed.

        e2e provisions and destroys real cloud resources, so it needs valid
        credentials at runtime (an authenticated 'az' session or ARM_*
        environment variables). Authentication is left to terraform and its
        providers; this engine performs no preflight.

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

    $issues = New-Object System.Collections.Generic.List[object]

    foreach ($example in $exampleDirs) {
        $exampleDir = $example.FullName
        $rel = ('examples/{0}' -f $example.Name)

        # 1. init against a real backend (e2e deploys real infrastructure).
        $init = Invoke-AvmProcess `
            -FilePath $tool.Path `
            -ArgumentList @('init', '-input=false', '-no-color') `
            -WorkingDirectory $exampleDir `
            -IgnoreExitCode

        if ($init.ExitCode -ne 0) {
            $detail = if ($init.StdErr) { $init.StdErr.Trim() } elseif ($init.StdOut) { $init.StdOut.Trim() } else { '' }
            $issues.Add((New-AvmE2eIssue -File $rel -Message ('terraform init failed (exit {0}): {1}' -f $init.ExitCode, $detail)))
            # Nothing was initialised, so there is nothing to destroy.
            continue
        }

        # 2. apply.
        $apply = Invoke-AvmProcess `
            -FilePath $tool.Path `
            -ArgumentList @('apply', '-auto-approve', '-input=false', '-no-color') `
            -WorkingDirectory $exampleDir `
            -IgnoreExitCode

        if ($apply.ExitCode -ne 0) {
            $detail = if ($apply.StdErr) { $apply.StdErr.Trim() } elseif ($apply.StdOut) { $apply.StdOut.Trim() } else { '' }
            $issues.Add((New-AvmE2eIssue -File $rel -Message ('terraform apply failed (exit {0}): {1}' -f $apply.ExitCode, $detail)))
        }
        else {
            # 3. idempotency: a second plan must report no changes.
            $plan = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('plan', '-detailed-exitcode', '-input=false', '-no-color') `
                -WorkingDirectory $exampleDir `
                -IgnoreExitCode

            # -detailed-exitcode: 0 = no changes, 2 = changes present, 1 = error.
            if ($plan.ExitCode -eq 2) {
                $issues.Add((New-AvmE2eIssue -File $rel -Message 'idempotency check failed: a second plan reported pending changes (exit 2).'))
            }
            elseif ($plan.ExitCode -ne 0) {
                $detail = if ($plan.StdErr) { $plan.StdErr.Trim() } elseif ($plan.StdOut) { $plan.StdOut.Trim() } else { '' }
                $issues.Add((New-AvmE2eIssue -File $rel -Message ('idempotency plan errored (exit {0}): {1}' -f $plan.ExitCode, $detail)))
            }
        }

        # 4. destroy - always attempt once init has succeeded, even after a
        #    failed apply, so a broken run does not leak real Azure resources.
        $destroy = Invoke-AvmProcess `
            -FilePath $tool.Path `
            -ArgumentList @('destroy', '-auto-approve', '-input=false', '-no-color') `
            -WorkingDirectory $exampleDir `
            -IgnoreExitCode

        if ($destroy.ExitCode -ne 0) {
            $detail = if ($destroy.StdErr) { $destroy.StdErr.Trim() } elseif ($destroy.StdOut) { $destroy.StdOut.Trim() } else { '' }
            $issues.Add((New-AvmE2eIssue -File $rel -Message ('terraform destroy failed (exit {0}): {1}' -f $destroy.ExitCode, $detail)))
        }
    }

    $status = if ($issues.Count -gt 0) { 'fail' } else { 'pass' }

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
        [string] $Message
    )

    [pscustomobject][ordered]@{
        File     = $File
        Line     = 0
        Column   = 0
        Severity = 'error'
        Code     = ''
        Message  = $Message
    }
}
