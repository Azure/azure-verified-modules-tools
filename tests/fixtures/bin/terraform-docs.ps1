# AVM test-only stub for `terraform-docs`.
# Handles only --version and the Invoke-AvmTerraformDocs argv shape
# (markdown table --output-file README.md --output-mode inject .).
# The stub does NOT mutate README so the engine reports Changed=@().

if ($args.Count -eq 0) {
    Write-Error 'stub terraform-docs: no arguments'
    exit 64
}

if ($args -contains '--version') {
    if ([string]::IsNullOrWhiteSpace($env:AVM_STUB_TOOL_VERSION)) {
        Write-Error 'stub terraform-docs: AVM_STUB_TOOL_VERSION is not set'
        exit 64
    }
    Write-Output "terraform-docs version v$env:AVM_STUB_TOOL_VERSION darwin/amd64"
    exit 0
}

if ($args[0] -eq 'markdown') {
    exit 0
}

Write-Error "stub terraform-docs: unhandled args '$($args -join ' ')'"
exit 64
