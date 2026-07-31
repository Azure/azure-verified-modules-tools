# AVM test-only stub for `conftest`. Pinned to avm.pins version 0.68.2 so
# Find-AvmToolOnPath's version match succeeds when the launcher is on PATH.
#
# Handles only the verbs Invoke-AvmTerraformCheckPolicy actually invokes:
# `--version` (so Resolve-AvmTool -AllowPathFallback succeeds) and `test`
# (which the engine drives as `test --policy <APRL> --policy <AVMSEC>
# --output json --parser hcl2 .`).
#
# Default `test` output mirrors what real conftest 0.68.2 emits for the pinned
# bundles under --parser hcl2: one record per input file in the default 'main'
# namespace with successes=0, because no bundled rule declares `package main`.
# The records are built by enumerating the working directory, so the stub also
# witnesses that the engine stages only Terraform sources (F48) - a real repo's
# .gitignore reaching conftest aborts it before any policy loads.
# Set $env:AVM_STUB_CONFTEST_OUTPUT to a JSON document to drive any other shape;
# the stub then exits 1 if that document carries failures, matching real
# conftest's exit contract.

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
            $inputs = @(Get-ChildItem -LiteralPath (Get-Location).Path -Recurse -File -ErrorAction SilentlyContinue |
                    ForEach-Object { [System.IO.Path]::GetRelativePath((Get-Location).Path, $_.FullName).Replace('\', '/') } |
                    Sort-Object)
            # Real conftest aborts in 'parse configurations' on the first file the
            # HCL parser cannot read, emitting nothing on stdout and exiting 1.
            $unparseable = @($inputs | Where-Object { $_ -notmatch '\.(tf|tfvars)$' })
            if ($unparseable.Count -gt 0) {
                [Console]::Error.WriteLine(('Error: running test: parse configurations: parser unmarshal: convert to bytes: parse config: [:1,1-2: Argument or block definition required], path: {0}' -f $unparseable[0]))
                exit 1
            }
            $records = @($inputs | ForEach-Object {
                    [pscustomobject][ordered]@{ filename = $_; namespace = 'main'; successes = 0 }
                })
            Write-Output (ConvertTo-Json -InputObject $records -Depth 4 -AsArray -Compress)
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
