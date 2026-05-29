# AVM test-only stub for `conftest`. Pinned to tools.lock version 0.68.2 so
# Find-AvmToolOnPath's version match succeeds when the launcher is on PATH.
#
# Handles only the verbs Invoke-AvmTerraformCheckPolicy actually invokes:
# `--version` (so Resolve-AvmTool -AllowPathFallback succeeds) and `test`
# (which the engine drives as `test --policy <APRL> --policy <AVMSEC>
# --output json --parser hcl2 .`). The happy "no issues" path emits an
# empty JSON array on stdout; integration consumers that need failures
# can swap the stub via a future $env:AVM_STUB_CONFTEST_OUTPUT escape
# hatch (not needed for the first consumer).

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
        # Empty JSON array == zero per-file records == zero issues.
        # Invoke-AvmTerraformCheckPolicy parses this as Status='pass'.
        Write-Output '[]'
        exit 0
    }
    default {
        Write-Error "stub conftest: unhandled verb '$($args[0])' (full args: $($args -join ' '))"
        exit 64
    }
}
