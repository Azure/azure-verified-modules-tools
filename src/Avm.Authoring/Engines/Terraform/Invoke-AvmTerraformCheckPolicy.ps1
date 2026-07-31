function Invoke-AvmTerraformCheckPolicy {
    <#
    .SYNOPSIS
        Run 'conftest test' against a Terraform module using the pinned
        APRL + AVMSEC policy bundles.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmCheckPolicy when the
        module context is Ecosystem='terraform'.

        Pipeline:

          1. Resolve the 'conftest' binary via Resolve-AvmTool (cache
             first; -AllowPathFallback enables PATH fallback when set).
          2. Resolve two policy bundles from the pinned policy library in
             the module's pin manifest (Resources/avm.pins.jsonc):
                avm-policy-aprl   - the Azure Proactive Resiliency Library bundle
                avm-policy-avmsec - the AVM Security bundle
             These ship with the module, so no repository configuration is
             required and the verb works on a clean checkout.
             AVM_POLICY_LIBRARY_REF + AVM_POLICY_LIBRARY_SHA256 override the
             pinned ref for testing an unreleased policy set; both are
             required together.
          3. Run conftest:
                conftest test --policy <APRL> --policy <AVMSEC>
                              [--policy <example-exception>]...
                              --output json --parser hcl2 .
             from CWD=$Context.Root. Per-example exception bundles are
             discovered as <Root>/examples/<name>/exceptions/*.rego (top-
             level glob only) and appended in ordinal-sorted order, so
             argv is stable across operating systems and locale.
          4. Parse the JSON output: an array of per-file/per-namespace
             records each carrying 'failures' (severity=error) and
             'warnings' (severity=warning) lists. Flatten into the shared
             Issue record shape.
          5. Decide the status. 'pass' is only reachable when policies were
             actually evaluated against the module - see below.

        conftest exit codes:
          0 - no failures (warnings allowed)
          1 - at least one failure (parse and report; Status='fail')
          others - conftest itself misbehaved (throw AvmProcessException)

        This slice uses the HCL2 parser so the engine can be exercised
        without first running 'terraform plan' against a configured Azure
        backend. The plan-JSON path (which APRL was originally designed
        for) is a deliberate follow-up slice.

        Because of that, this engine cannot currently return 'pass'. Two
        independent facts make every HCL2 run vacuous:

          a. conftest evaluates only its default 'main' namespace unless
             told otherwise, and not one rule in the pinned bundles
             declares 'package main' - so 0 policies are evaluated.
          b. the bundles destructure 'terraform show -json' shapes
             (plan.resource_changes / configuration), so even with
             --all-namespaces every rule matches no resource and is
             counted as a success.

        Both are reported as Status='skipped' with a diagnostic naming the
        reason, never 'pass'. Reporting 'pass' would make a gate that has
        never been capable of failing indistinguishable from one that
        checked the module and found nothing wrong - the same class of
        defect as a test tier that runs no tests. Adding --all-namespaces
        alone would move (a) to (b) rather than fixing anything, which is
        why (b) is detected independently. When the plan-JSON slice lands,
        $parserMode stops being 'hcl2' and both skips stop firing.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        Evaluated, Issues.
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
            "Invoke-AvmTerraformCheckPolicy requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'conftest' -AllowPathFallback:$AllowPathFallback

    $aprlName = 'avm-policy-aprl'
    $avmsecName = 'avm-policy-avmsec'

    $aprlAsset = Resolve-AvmPolicyBundle -Name $aprlName
    $avmsecAsset = Resolve-AvmPolicyBundle -Name $avmsecName

    # Per-example exceptions: examples/<name>/exceptions/*.rego (top-level glob;
    # spec wording is one level deep). Each match is appended as an additional
    # --policy <path> pair after APRL+AVMSEC so the base bundles still win on
    # ordering. Sorted by FullName with [StringComparer]::Ordinal so argv is
    # stable across operating systems and locale.
    $exceptionPolicies = @()
    $examplesRoot = Join-Path $Context.Root 'examples'
    if (Test-Path -LiteralPath $examplesRoot -PathType Container) {
        $exampleDirs = Get-ChildItem -LiteralPath $examplesRoot -Directory -ErrorAction SilentlyContinue
        $exceptionMatches = New-Object 'System.Collections.Generic.List[string]'
        foreach ($example in $exampleDirs) {
            $exceptionsDir = Join-Path $example.FullName 'exceptions'
            if (-not (Test-Path -LiteralPath $exceptionsDir -PathType Container)) { continue }
            $regoFiles = Get-ChildItem -LiteralPath $exceptionsDir -File -Filter '*.rego' -ErrorAction SilentlyContinue
            foreach ($file in $regoFiles) {
                $exceptionMatches.Add($file.FullName)
            }
        }
        if ($exceptionMatches.Count -gt 0) {
            $arr = $exceptionMatches.ToArray()
            [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
            $exceptionPolicies = $arr
        }
    }

    $parserMode = 'hcl2'

    $argList = New-Object 'System.Collections.Generic.List[string]'
    $argList.Add('test')
    $argList.Add('--policy'); $argList.Add($aprlAsset.Path)
    $argList.Add('--policy'); $argList.Add($avmsecAsset.Path)
    foreach ($exception in $exceptionPolicies) {
        $argList.Add('--policy'); $argList.Add($exception)
    }
    $argList.Add('--output'); $argList.Add('json')
    $argList.Add('--parser'); $argList.Add($parserMode)
    $argList.Add('.')

    $result = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList $argList.ToArray() `
        -WorkingDirectory $Context.Root `
        -IgnoreExitCode

    # exit 0 = no failures; 1 = at least one failure; anything else = conftest itself misbehaved.
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 1) {
        $stderr = if ($result.StdErr) { $result.StdErr.Trim() } else { '' }
        $tail = if ($stderr) { ": $stderr" } else { '.' }
        throw [AvmProcessException]::new(
            ('conftest exited with code {0}{1}' -f $result.ExitCode, $tail))
    }

    $issues = New-Object System.Collections.Generic.List[object]
    $evaluated = 0
    $namespaces = New-Object System.Collections.Generic.HashSet[string]
    $payload = if ($result.StdOut) { $result.StdOut.Trim() } else { '' }
    if ($payload) {
        try {
            $parsed = $payload | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw [AvmProcessException]::new(
                "Could not parse conftest --output json output: $($_.Exception.Message)")
        }
        foreach ($record in @($parsed)) {
            if (-not $record) { continue }
            $file = if ($record.PSObject.Properties['filename']) { [string]$record.filename } else { '' }
            $namespace = if ($record.PSObject.Properties['namespace']) { [string]$record.namespace } else { '' }
            if ($namespace) { $null = $namespaces.Add($namespace) }

            if ($record.PSObject.Properties['successes']) { $evaluated += [int]$record.successes }
            foreach ($bucket in @('failures', 'warnings', 'exceptions')) {
                if ($record.PSObject.Properties[$bucket] -and $record.$bucket) {
                    $evaluated += @($record.$bucket).Count
                }
            }

            if ($record.PSObject.Properties['failures'] -and $record.failures) {
                foreach ($failure in @($record.failures)) {
                    $msg = if ($failure.PSObject.Properties['msg']) { [string]$failure.msg } else { '' }
                    $issues.Add([pscustomobject][ordered]@{
                            File     = $file
                            Line     = 0
                            Column   = 0
                            Severity = 'error'
                            Code     = $namespace
                            Message  = $msg
                        })
                }
            }
            if ($record.PSObject.Properties['warnings'] -and $record.warnings) {
                foreach ($warning in @($record.warnings)) {
                    $msg = if ($warning.PSObject.Properties['msg']) { [string]$warning.msg } else { '' }
                    $issues.Add([pscustomobject][ordered]@{
                            File     = $file
                            Line     = 0
                            Column   = 0
                            Severity = 'warning'
                            Code     = $namespace
                            Message  = $msg
                        })
                }
            }
        }
    }

    $errorCount = @($issues | Where-Object { $_.Severity -eq 'error' }).Count
    $nsList = if ($namespaces.Count -gt 0) { (@($namespaces) | Sort-Object) -join ', ' } else { '(none)' }

    # Only reachable when no rule produced any finding: a rule that fired proves
    # the input shape matched, so the vacuity premise below does not hold.
    $skipReason = $null
    if ($issues.Count -eq 0) {
        if ($evaluated -eq 0) {
            $skipReason = ("conftest evaluated 0 policies (namespaces seen: {0}). The pinned APRL + AVMSEC bundles declare no rules in conftest's default 'main' namespace, so nothing was checked." -f $nsList)
        }
        elseif ($parserMode -ne 'json') {
            $skipReason = ("conftest evaluated {0} policies from the '{1}' parser, but the pinned APRL + AVMSEC bundles destructure 'terraform show -json' shapes, so no rule can match a resource and every rule is counted as a success." -f $evaluated, $parserMode)
        }
    }

    if ($skipReason) {
        Write-AvmLog $skipReason -Level Warning
        # Never 'pass': a gate that cannot fail must not be indistinguishable
        # from one that checked the module and found nothing wrong.
        $status = 'skipped'
        $issues.Add([pscustomobject][ordered]@{
                File     = ''
                Line     = 0
                Column   = 0
                Severity = 'warning'
                Code     = 'avm.tf.policy-not-evaluated'
                Message  = ('{0} Policy evaluation requires the plan-JSON input path, which is a tracked follow-up slice.' -f $skipReason)
            })
    }
    else {
        $status = if ($errorCount -gt 0) { 'fail' } else { 'pass' }
    }

    return [pscustomobject][ordered]@{
        Engine     = 'terraform'
        Tool       = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath   = $tool.Path
        ToolSource = $tool.Source
        Status     = $status
        Evaluated  = $evaluated
        Issues     = $issues.ToArray()
    }
}
