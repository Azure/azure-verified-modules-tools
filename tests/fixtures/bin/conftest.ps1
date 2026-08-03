# AVM test-only stub for `conftest`. Pinned to avm.pins version 0.68.2 so
# Find-AvmToolOnPath's version match succeeds when the launcher is on PATH.
#
# Handles only `--version` and the plan-JSON `test` invocation used by the
# Terraform policy engine.
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
            if ($args -notcontains '--all-namespaces' -or $args[-1] -ne 'tfplan.json') {
                [Console]::Error.WriteLine('stub conftest: expected --all-namespaces and tfplan.json input')
                exit 1
            }
            $namespace = if (($args -join ' ') -match '(?i)(^|[\\/])avmsec($|[\\/ ])') {
                'avmsec'
            }
            else {
                'Azure_Proactive_Resiliency_Library_v2'
            }
            Write-Output (ConvertTo-Json -InputObject ([pscustomobject][ordered]@{
                        filename  = 'tfplan.json'
                        namespace = $namespace
                        successes = 130
                    }) -Depth 4 -Compress)
            exit 0
        }

        $records = @($override | ConvertFrom-Json -ErrorAction Stop)
        $isAvmsec = ($args -join ' ') -match '(?i)(^|[\\/])avmsec($|[\\/ ])'
        $records = @($records | Where-Object {
                if ($isAvmsec) {
                    $_.namespace -eq 'avmsec'
                }
                else {
                    $_.namespace -ne 'avmsec'
                }
            })
        Write-Output (ConvertTo-Json -InputObject $records -Depth 8 -Compress)
        $hasFailures = $false
        try {
            foreach ($record in $records) {
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
