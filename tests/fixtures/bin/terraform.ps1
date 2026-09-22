# AVM test-only stub for `terraform`.
# This stub handles only the verbs the Terraform engine wrappers invoke.
# Anything else is a bug — fail loudly so the test surfaces the gap.

$toolVersion = $env:AVM_STUB_TOOL_VERSION
if ([string]::IsNullOrWhiteSpace($toolVersion)) {
    Write-Error 'stub terraform: AVM_STUB_TOOL_VERSION is not set'
    exit 64
}

if ($args.Count -eq 0) {
    Write-Error 'stub terraform: no arguments'
    exit 64
}

if ($env:AVM_STUB_TERRAFORM_TRACE) {
    [ordered]@{
        Command = $args[0]
        Directory = (Get-Location).Path
        DataDirectory = $env:TF_DATA_DIR
    } | ConvertTo-Json -Compress |
        Add-Content -LiteralPath $env:AVM_STUB_TERRAFORM_TRACE -Encoding utf8NoBOM
}

switch ($args[0]) {
    '--version' {
        Write-Output "Terraform v$toolVersion"
        Write-Output 'on linux_amd64'
        exit 0
    }
    'fmt' {
        # Empty stdout signals "no files changed" to Format-AvmTerraformModule.
        exit 0
    }
    'init' {
        if ($env:TF_DATA_DIR) {
            $modulesDirectory = Join-Path $env:TF_DATA_DIR 'modules'
            $null = New-Item -ItemType Directory -Path $modulesDirectory -Force
            $fixture = Join-Path (Get-Location).Path '.avm-stub-modules.json'
            $manifest = if (Test-Path -LiteralPath $fixture -PathType Leaf) {
                Get-Content -LiteralPath $fixture -Raw
            }
            else {
                '{"Modules":[{"Key":"","Source":"","Dir":"."}]}'
            }
            Set-Content -LiteralPath (Join-Path $modulesDirectory 'modules.json') -Value $manifest -Encoding utf8NoBOM
        }
        Write-Output ''
        Write-Output 'Initializing the backend...'
        Write-Output ''
        Write-Output 'Terraform has been successfully initialized!'
        exit 0
    }
    'validate' {
        $fixture = Join-Path (Get-Location).Path '.avm-stub-validation.json'
        $payload = if (Test-Path -LiteralPath $fixture -PathType Leaf) {
            Get-Content -LiteralPath $fixture -Raw
        }
        else {
            '{"format_version":"1.0","valid":true,"error_count":0,"warning_count":0,"diagnostics":[]}'
        }
        Write-Output $payload
        if (($payload | ConvertFrom-Json).valid) { exit 0 }
        exit 1
    }
    'test' {
        if ($env:AVM_STUB_TERRAFORM_TEST_REGIONS) {
            if ($env:TF_CLI_ARGS_test -ne '-filter=tests/integration/deploy.tftest.hcl') {
                Write-Error 'stub terraform: expected the selected integration test filter'
                exit 64
            }
            $testPath = 'tests/integration/deploy.tftest.hcl'
            $resourcePath = Join-Path (Get-Location).Path 'stub-owned-resource.txt'
            $attemptPath = Join-Path (Get-Location).Path 'stub-test-attempt.txt'
            if (Test-Path -LiteralPath $resourcePath) {
                Write-Error 'stub terraform: previous attempt was not cleaned up'
                exit 65
            }
            $attempt = if (Test-Path -LiteralPath $attemptPath) { [int](Get-Content -LiteralPath $attemptPath -Raw) + 1 } else { 1 }
            Set-Content -LiteralPath $attemptPath -Value $attempt -Encoding utf8NoBOM
            $regions = @($env:AVM_STUB_TERRAFORM_TEST_REGIONS | ConvertFrom-Json)
            $region = $regions[($attempt - 1) % $regions.Count]
            Set-Content -LiteralPath $resourcePath -Value $region -Encoding utf8NoBOM
            [ordered]@{
                Command = 'test-region'; Directory = (Get-Location).Path
                Region = $region; Attempt = $attempt; Filter = $env:TF_CLI_ARGS_test
            } | ConvertTo-Json -Compress |
                Add-Content -LiteralPath $env:AVM_STUB_TERRAFORM_TRACE -Encoding utf8NoBOM

            $failed = $region -eq 'restricted-test-region'
            $assertion = $env:AVM_STUB_TERRAFORM_TEST_MODE -eq 'assertion'
            $cleanupFailure = $env:AVM_STUB_TERRAFORM_TEST_MODE -eq 'cleanup'
            $runStatus = if ($assertion) { 'fail' } elseif ($failed) { 'error' } else { 'pass' }
            $status = if ($assertion) { 'fail' } elseif ($failed -or $cleanupFailure) { 'error' } else { 'pass' }
            $events = @(
                @{ type = 'test_abstract'; test_abstract = @{ $testPath = @('setup', 'deploy', 'update') } }
                @{ type = 'test_file'; test_file = @{ path = $testPath; progress = 'starting' } }
                @{ type = 'test_run'; test_run = @{ path = $testPath; run = 'setup'; progress = 'complete'; status = 'pass' } }
                @{ type = 'test_run'; test_run = @{ path = $testPath; run = 'deploy'; progress = 'complete'; status = $runStatus } }
            )
            if ($failed -or $assertion) {
                $events += @{
                    type = 'diagnostic'; '@level' = 'error'; '@testfile' = $testPath; '@testrun' = 'deploy'
                    diagnostic = @{
                        severity = 'error'
                        summary = if ($assertion) { 'Test assertion failed' } else { 'Error creating/updating resource' }
                        detail = 'unexpected status 403 (403 Forbidden): RequestDisallowedByAzure: region not accepting new customers. https://aka.ms/locationineligible'
                        range = @{ filename = 'main.tf'; start = @{ line = 12; column = 3 } }
                    }
                }
            }
            $events += @(
                @{ type = 'test_run'; test_run = @{ path = $testPath; run = 'update'; progress = 'complete'; status = if ($failed -or $assertion) { 'skip' } else { 'pass' } } }
                @{ type = 'test_file'; test_file = @{ path = $testPath; progress = 'teardown' } }
                @{ type = 'test_run'; test_run = @{ path = $testPath; run = 'setup'; progress = 'teardown' } }
            )
            foreach ($entry in $events) { ConvertTo-Json -InputObject $entry -Depth 10 -Compress }
            if ($cleanupFailure) {
                @{
                    type = 'test_cleanup'; '@level' = 'error'; '@testfile' = $testPath
                    '@message' = 'Terraform left the stub resource; manual cleanup is required.'
                } | ConvertTo-Json -Compress
            }
            else {
                Remove-Item -LiteralPath $resourcePath
            }
            [ordered]@{
                Command = 'test-cleanup'; Directory = (Get-Location).Path
                Region = $region; ExitCode = if ($cleanupFailure) { 1 } else { 0 }
            } | ConvertTo-Json -Compress |
                Add-Content -LiteralPath $env:AVM_STUB_TERRAFORM_TRACE -Encoding utf8NoBOM
            @{
                type = 'test_file'; test_file = @{ path = $testPath; progress = 'complete'; status = $status }
            } | ConvertTo-Json -Compress
            @{
                type = 'test_summary'
                test_summary = @{
                    status = $status
                    passed = if ($failed -or $assertion) { 1 } else { 3 }
                    failed = if ($assertion) { 1 } else { 0 }
                    errored = if ($failed -and -not $assertion) { 1 } else { 0 }
                    skipped = if ($failed -or $assertion) { 1 } else { 0 }
                }
            } | ConvertTo-Json -Compress
            if ($status -ne 'pass') { exit 1 }
            exit 0
        }

        # Emit a minimal newline-delimited JSON stream that the suite engine
        # tolerates. No test_run failures and no error diagnostics => the
        # engine reports Status=pass. Exit 0 = every run passed.
        Write-Output '{"@level":"info","type":"test_run","test_run":{"path":"tests/unit/main.tftest.hcl","run":"stub","status":"pass"}}'
        Write-Output '{"@level":"info","type":"test_summary","test_summary":{"status":"pass","passed":1,"failed":0,"errored":0,"skipped":0}}'
        exit 0
    }
    'apply' {
        # e2e engine invokes 'apply -auto-approve ...'. Report a clean deploy.
        Write-Output 'Apply complete! Resources: 1 added, 0 changed, 0 destroyed.'
        exit 0
    }
    'plan' {
        $outArg = @($args | Where-Object { $_ -like '-out=*' } | Select-Object -First 1)
        if ($outArg.Count -gt 0) {
            $planName = $outArg[0].Substring('-out='.Length)
            Set-Content -LiteralPath (Join-Path (Get-Location).Path $planName) -Value 'stub plan' -Encoding utf8
        }
        Write-Output 'No changes. Your infrastructure matches the configuration.'
        exit 0
    }
    'show' {
        Write-Output '{"format_version":"1.2","terraform_version":"__VERSION__","planned_values":{"root_module":{"resources":[]}},"resource_changes":[],"configuration":{"root_module":{"resources":[]}}}'.Replace('__VERSION__', $toolVersion)
        exit 0
    }
    'destroy' {
        # e2e engine always tears down with 'destroy -auto-approve ...'.
        Write-Output 'Destroy complete! Resources: 1 destroyed.'
        exit 0
    }
    default {
        Write-Error "stub terraform: unhandled verb '$($args[0])' (full args: $($args -join ' '))"
        exit 64
    }
}
