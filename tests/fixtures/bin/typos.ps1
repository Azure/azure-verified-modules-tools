# AVM test-only stub for `typos`. Pinned to avm.pins 1.49.0.
# Handles only --version and the Invoke-AvmTerraformCheckSpelling argv shape
# (--config <path> --format json <root>).
#
# Emits whatever newline-delimited JSON $env:AVM_STUB_TYPOS_OUTPUT holds, with
# exit code 2 when it is non-empty (typos' "findings" code) and 0 otherwise, so
# a component test can drive both the clean and the dirty path.

if ($args.Count -eq 0) {
    Write-Error 'stub typos: no arguments'
    exit 64
}

if ($args -contains '--version') {
    Write-Output 'typos 1.49.0'
    exit 0
}

if ($args -contains '--write-changes' -or $args -contains '-w') {
    Write-Error 'stub typos: the engine must never request auto-fix'
    exit 64
}

if ($args -contains '--format') {
    $payload = $env:AVM_STUB_TYPOS_OUTPUT
    if ([string]::IsNullOrWhiteSpace($payload)) {
        exit 0
    }
    Write-Output $payload
    exit 2
}

Write-Error "stub typos: unhandled args '$($args -join ' ')'"
exit 64
