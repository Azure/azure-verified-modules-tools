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
    default {
        Write-Error "stub terraform: unhandled verb '$($args[0])' (full args: $($args -join ' '))"
        exit 64
    }
}
