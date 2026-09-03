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
        Write-Output ''
        Write-Output 'Initializing the backend...'
        Write-Output ''
        Write-Output 'Terraform has been successfully initialized!'
        exit 0
    }
    'validate' {
        Write-Output '{"format_version":"1.0","valid":true,"error_count":0,"warning_count":0,"diagnostics":[]}'
        exit 0
    }
    'test' {
        # Emit a minimal newline-delimited JSON stream that the suite engine
        # and policy engine tolerate. The policy engine consumes test_plan;
        # the suite engine consumes test_run and test_summary.
        Write-Output ('{"@level":"info","type":"version","terraform":"{0}","ui":"1.3"}' -f $toolVersion)
        Write-Output '{"@level":"info","type":"test_run","test_run":{"path":"tests/unit/main.tftest.hcl","run":"stub","status":"pass"}}'
        Write-Output '{"@level":"info","type":"test_plan","test_plan":{"plan_format_version":"1.2","resource_changes":[],"provider_schemas":{}}}'
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
