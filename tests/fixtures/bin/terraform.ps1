# AVM test-only stub for `terraform`. Pinned to the version recorded in
# src/Avm.Authoring/Resources/tools.lock.psd1 (terraform 1.15.3) so
# Find-AvmToolOnPath's version match succeeds when the launcher is on PATH.
#
# This stub handles only the verbs the Terraform engine wrappers invoke.
# Anything else is a bug — fail loudly so the test surfaces the gap.

if ($args.Count -eq 0) {
    Write-Error 'stub terraform: no arguments'
    exit 64
}

switch ($args[0]) {
    '--version' {
        Write-Output 'Terraform v1.15.3'
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
        # e2e idempotency check runs 'plan -detailed-exitcode ...'. Exit 0 =
        # no changes (idempotent). The engine treats exit 2 as drift; the stub
        # always reports a clean, idempotent plan.
        Write-Output 'No changes. Your infrastructure matches the configuration.'
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
