# AVM test-only stub for `conftest`.
# Handles version checks, declared HCL parsing fixtures and plan-JSON policy tests.
# Set $env:AVM_STUB_CONFTEST_OUTPUT to a JSON document to drive any other shape;
# the stub then exits 1 if that document carries failures, matching real
# conftest's exit contract.

if ($args.Count -eq 0) {
    Write-Error 'stub conftest: no arguments'
    exit 64
}

switch ($args[0]) {
    '--version' {
        if ([string]::IsNullOrWhiteSpace($env:AVM_STUB_TOOL_VERSION)) {
            Write-Error 'stub conftest: AVM_STUB_TOOL_VERSION is not set'
            exit 64
        }
        Write-Output "Version: $env:AVM_STUB_TOOL_VERSION"
        exit 0
    }
    'parse' {
            if ($args.Count -lt 5 -or $args[1] -ne '--parser' -or $args[2] -ne 'hcl2' -or $args[3] -ne '--combine') {
                Write-Error 'stub conftest: expected parse --parser hcl2 --combine followed by files'
                exit 64
            }
            $records = @(
                foreach ($path in $args[4..($args.Count - 1)]) {
                    $text = Get-Content -LiteralPath $path -Raw
                    $fixturePath = Join-Path (Split-Path -Parent $path) '.avm-stub-hcl.json'
                    if (Test-Path -LiteralPath $fixturePath -PathType Leaf) {
                        $fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -AsHashtable
                        $name = Split-Path -Leaf $path
                        if (-not $fixture.Contains($name)) {
                            Write-Error "stub conftest: no parsed fixture for '$name'"
                            exit 64
                        }
                        $contents = $fixture[$name]
                    }
                    elseif ($text -match '(?s)^\s*(#[^\r\n]*\r?\n)?terraform\s*\{\s*required_version\s*=\s*">= 1\.0"\s*\}\s*$') {
                        $contents = @{ terraform = @(@{ required_version = '>= 1.0' }) }
                    }
                    else {
                        Write-Error "stub conftest: unsupported HCL fixture '$path'"
                        exit 64
                    }
                    @{ path = $path; contents = $contents }
                }
            )
            ConvertTo-Json -InputObject $records -Depth 50 -Compress
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
