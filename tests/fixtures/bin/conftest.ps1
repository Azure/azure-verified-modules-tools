# AVM test-only stub for `conftest`. Pinned to avm.pins version 0.68.2 so
# Find-AvmToolOnPath's version match succeeds when the launcher is on PATH.
#
# Handles only the verbs Invoke-AvmTerraformCheckPolicy actually invokes:
# `--version` (so Resolve-AvmTool -AllowPathFallback succeeds) and `test`
# (which the engine drives as `test --policy <APRL> --policy <AVMSEC>
# --output json --parser hcl2 .`).
#
# Default `test` output is an empty JSON array, which is what real conftest
# emits today for the pinned bundles under --parser hcl2: zero policies
# evaluated. Set $env:AVM_STUB_CONFTEST_OUTPUT to a JSON document to drive
# any other shape; the stub then exits 1 if that document carries failures,
# matching real conftest's exit contract.

if ($args.Count -eq 0) {
    Write-Error 'stub conftest: no arguments'
    exit 64
}

switch ($args[0]) {
    '--version' {
        Write-Output 'Version: 0.68.2'
        exit 0
    }
    'test' {
        $override = $env:AVM_STUB_CONFTEST_OUTPUT
        if ([string]::IsNullOrWhiteSpace($override)) {
            # Empty JSON array == zero per-file records == zero policies
            # evaluated, which Invoke-AvmTerraformCheckPolicy reports as
            # Status='skipped' rather than a pass it cannot justify.
            Write-Output '[]'
            exit 0
        }

        Write-Output $override
        $hasFailures = $false
        try {
            foreach ($record in @($override | ConvertFrom-Json -ErrorAction Stop)) {
                if ($record -and $record.PSObject.Properties['failures'] -and $record.failures) {
                    $hasFailures = $true
                }
            }
        }
        catch {
            Write-Error "stub conftest: AVM_STUB_CONFTEST_OUTPUT is not valid JSON: $($_.Exception.Message)"
            exit 64
        }
        if ($hasFailures) { exit 1 }
        exit 0
    }
    default {
        Write-Error "stub conftest: unhandled verb '$($args[0])' (full args: $($args -join ' '))"
        exit 64
    }
}
