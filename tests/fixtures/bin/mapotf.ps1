# AVM test-only stub for `mapotf`. Pinned to tools.lock version 0.1.4 so
# Find-AvmToolOnPath's version match succeeds when the launcher is on PATH.
#
# Handles only the verbs Invoke-AvmTerraformTransform actually invokes:
# `--version` (so Resolve-AvmTool -AllowPathFallback succeeds), `transform`
# (driven as `transform --mptf-dir <configs> --tf-dir <root>`) and
# `clean-backup` (driven as `clean-backup --tf-dir <root>`). Both verbs are
# deterministic no-ops here: the stub mutates nothing, so the engine's
# before/after hash snapshot yields an empty change set (Status='pass', and
# no drift under -CheckDrift). A future $env:AVM_STUB_MAPOTF_* escape hatch
# can simulate a real transform/drift if an Integration test needs it.

if ($args.Count -eq 0) {
    Write-Error 'stub mapotf: no arguments'
    exit 64
}

switch ($args[0]) {
    '--version' {
        Write-Output 'Version: 0.1.4'
        exit 0
    }
    'transform' {
        # No-op: leave every *.tf untouched so the engine reports no changes.
        exit 0
    }
    'clean-backup' {
        # No-op: the no-op transform left no *.tf.mptfbackup files to remove.
        exit 0
    }
    default {
        Write-Error "stub mapotf: unhandled verb '$($args[0])' (full args: $($args -join ' '))"
        exit 64
    }
}
