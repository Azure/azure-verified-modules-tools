# AVM test-only stub for `terraform-docs`. Pinned to tools.lock 0.20.0.
# Handles only --version and the Invoke-AvmTerraformDocs argv shape
# (markdown table --output-file README.md --output-mode inject .).
# The stub does NOT mutate README so the engine reports Changed=@().

if ($args.Count -eq 0) {
    Write-Error 'stub terraform-docs: no arguments'
    exit 64
}

if ($args -contains '--version') {
    Write-Output 'terraform-docs version v0.20.0 darwin/amd64'
    exit 0
}

if ($args[0] -eq 'markdown') {
    exit 0
}

Write-Error "stub terraform-docs: unhandled args '$($args -join ' ')'"
exit 64
