# AVM test-only stub for `tflint`. Pinned to tools.lock version 0.55.1.
# Handles only --version and the Invoke-AvmTerraformLint argv shape.

if ($args.Count -eq 0) {
    Write-Error 'stub tflint: no arguments'
    exit 64
}

if ($args -contains '--version') {
    Write-Output 'TFLint version 0.55.1'
    exit 0
}

if ($args -contains '--recursive') {
    # Empty issues array — Invoke-AvmTerraformLint parses this as a pass.
    Write-Output '{"issues":[]}'
    exit 0
}

Write-Error "stub tflint: unhandled args '$($args -join ' ')'"
exit 64
