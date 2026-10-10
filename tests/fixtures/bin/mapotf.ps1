# AVM test-only stub for `mapotf`.
# Transforms are no-ops; native inspection accepts only the empty component fixture.

if ($args.Count -eq 0) {
    Write-Error 'stub mapotf: no arguments'
    exit 64
}

switch ($args[0]) {
    '--version' {
        if ([string]::IsNullOrWhiteSpace($env:AVM_STUB_TOOL_VERSION)) {
            Write-Error 'stub mapotf: AVM_STUB_TOOL_VERSION is not set'
            exit 64
        }
        Write-Output "Version: $env:AVM_STUB_TOOL_VERSION"
        exit 0
    }
    'transform' {
        # No-op: leave every *.tf untouched so the engine reports no changes.
        exit 0
    }
    'debug' {
        $fileIndex = [array]::IndexOf($args, '--test-file')
        $rootIndex = [array]::IndexOf($args, '--tf-dir')
        if ($fileIndex -lt 0 -or $rootIndex -lt 0 -or
            $fileIndex + 1 -ge $args.Count -or $rootIndex + 1 -ge $args.Count) {
            Write-Error 'stub mapotf: debug requires --tf-dir and --test-file'
            exit 64
        }
        $testFile = Join-Path $args[$rootIndex + 1] $args[$fileIndex + 1]
        if ((Get-Content -LiteralPath $testFile -Raw -ErrorAction Stop).Trim() -cne '# fixture') {
            Write-Error 'stub mapotf: native inspection supports only the empty component fixture'
            exit 64
        }
        Write-Output '{"test":{"variables":null,"runs":{},"run_modules":{},"mock_providers":{},"providers":{}},"modules":{}}'
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
