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

function Write-StubTerraformTrace {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Record
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Record -Compress) + "`n")
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $stream = $null
    while ($null -eq $stream) {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ($timer.Elapsed.TotalSeconds -ge 10) {
                throw [System.IO.IOException]::new("Could not append the fixture trace '$Path' within ten seconds.", $_.Exception)
            }
            Start-Sleep -Milliseconds 10
        }
    }
    try {
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
}

if ($env:AVM_STUB_TERRAFORM_TRACE) {
    Write-StubTerraformTrace -Path $env:AVM_STUB_TERRAFORM_TRACE -Record ([ordered]@{
        Command = $args[0]
        Directory = (Get-Location).Path
        DataDirectory = $env:TF_DATA_DIR
        SkipRegistration = $env:ARM_SKIP_PROVIDER_REGISTRATION
        RegistrationMode = $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS
    })
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
    'providers' {
        if (($args -join ' ') -ne 'providers schema -json') {
            Write-Error 'stub terraform: expected providers schema -json'
            exit 64
        }
        $fixture = Join-Path (Get-Location).Path '.avm-stub-provider-schemas.json'
        if (Test-Path -LiteralPath $fixture -PathType Leaf) {
            Get-Content -LiteralPath $fixture -Raw
        }
        else {
            Write-Output '{"format_version":"1.0","provider_schemas":{}}'
        }
        exit 0
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
            Write-StubTerraformTrace -Path $env:AVM_STUB_TERRAFORM_TRACE -Record ([ordered]@{
                Command = 'test-region'; Directory = (Get-Location).Path
                Region = $region; Attempt = $attempt; Filter = $env:TF_CLI_ARGS_test
            })

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
            Write-StubTerraformTrace -Path $env:AVM_STUB_TERRAFORM_TRACE -Record ([ordered]@{
                Command = 'test-cleanup'; Directory = (Get-Location).Path
                Region = $region; ExitCode = if ($cleanupFailure) { 1 } else { 0 }
            })
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
        if ($env:AVM_STUB_TERRAFORM_E2E_REGIONS) {
            # The region stays in state until destroy, like random_integer.region_index.
            $statePath = Join-Path (Get-Location).Path 'stub-e2e-region.txt'
            if (-not (Test-Path -LiteralPath $statePath)) {
                $attemptPath = Join-Path (Get-Location).Path 'stub-e2e-attempt.txt'
                $attempt = if (Test-Path -LiteralPath $attemptPath) { [int](Get-Content -LiteralPath $attemptPath -Raw) + 1 } else { 1 }
                Set-Content -LiteralPath $attemptPath -Value $attempt -Encoding utf8NoBOM
                $regions = @($env:AVM_STUB_TERRAFORM_E2E_REGIONS | ConvertFrom-Json)
                Set-Content -LiteralPath $statePath -Value $regions[($attempt - 1) % $regions.Count] -Encoding utf8NoBOM
            }
            $region = (Get-Content -LiteralPath $statePath -Raw).Trim()
            Write-StubTerraformTrace -Path $env:AVM_STUB_TERRAFORM_TRACE -Record ([ordered]@{
                Command = 'apply-region'; Directory = (Get-Location).Path; Region = $region
            })
            if ($region -eq 'restricted-test-region') {
                $message = @(
                    'Error: creating Virtual Network (Subscription: "00000000-0000-0000-0000-000000000000"'
                    'Resource Group Name: "rg-test"'
                    'Virtual Network Name: "example"): performing CreateOrUpdate: unexpected status 403 (403 Forbidden) with error: RequestDisallowedByAzure: Resource ''example'' was disallowed by Azure: The selected region is currently not accepting new customers: https://aka.ms/locationineligible.'
                ) -join "`n"
                [Console]::Error.WriteLine($message)
                exit 1
            }
        }
        # e2e engine invokes 'apply -auto-approve ...'. Report a clean deploy.
        Write-Output 'Apply complete! Resources: 1 added, 0 changed, 0 destroyed.'
        exit 0
    }
    'plan' {
        if ($env:AVM_STUB_REQUIRE_POLICY_SAFETY -eq '1') {
            if ($env:ARM_SKIP_PROVIDER_REGISTRATION -ne 'true' -or $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS -ne 'legacy') {
                Write-Error 'stub terraform: implicit provider registration was not disabled'
                exit 65
            }
            $guards = @(Get-ChildItem -LiteralPath (Get-Location).Path -Filter '*_override.tf.json' |
                    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable })
            $guard = $guards | Where-Object { $_.provider.Contains('azapi') -and $_.provider.Contains('azure') } | Select-Object -Last 1
            if (-not $guard -or $guard.provider.azapi[0].skip_provider_registration -ne $true -or
                $guard.provider.azure[0].resource_provider_registrations -ne 'none' -or
                $guard.provider.azure[0].skip_provider_registration -ne $false -or
                $guard.provider.azure[0].resource_providers_to_register.Count -ne 0) {
                Write-Error 'stub terraform: explicit provider registration was not disabled before plan'
                exit 65
            }
        }
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
        if ($env:AVM_STUB_TERRAFORM_E2E_REGIONS) {
            Remove-Item -LiteralPath (Join-Path (Get-Location).Path 'stub-e2e-region.txt') -ErrorAction SilentlyContinue
        }
        # e2e engine always tears down with 'destroy -auto-approve ...'.
        Write-Output 'Destroy complete! Resources: 1 destroyed.'
        exit 0
    }
    default {
        Write-Error "stub terraform: unhandled verb '$($args[0])' (full args: $($args -join ' '))"
        exit 64
    }
}
