# AVM test-only stub for TFLint with the AVM ruleset.
# Handles only --version and the Invoke-AvmTerraformLint argv shape:
#   tflint --init --config <abs ruleset>
#   tflint --config <abs ruleset> --format=json --minimum-failure-severity=<sev>
# The --config path is asserted to exist so the component tier proves the
# engine hands tflint a resolvable absolute path to a vendored AVM ruleset.
#
# Note: the launcher shim routes through `pwsh -File`, which splits any
# '-flag=value' token at the first '=' or ':'. Match on flag names only.

if ($args.Count -eq 0) {
    Write-Error 'stub tflint: no arguments'
    exit 64
}

if ($args -contains '--version') {
    if ([string]::IsNullOrWhiteSpace($env:AVM_STUB_TOOL_VERSION) -or
        [string]::IsNullOrWhiteSpace($env:AVM_STUB_TFLINT_AVM_PLUGIN_VERSION)) {
        Write-Error 'stub tflint: launcher versions are not set'
        exit 64
    }
    Write-Output "TFLint version $env:AVM_STUB_TOOL_VERSION"
    Write-Output "ruleset.avm ($env:AVM_STUB_TFLINT_AVM_PLUGIN_VERSION)"
    exit 0
}

$configIndex = [array]::IndexOf([string[]]$args, '--config')
if ($configIndex -lt 0 -or $configIndex -eq $args.Count - 1) {
    Write-Error "stub tflint: missing '--config <path>' in '$($args -join ' ')'"
    exit 64
}

$configPath = $args[$configIndex + 1]
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Error "stub tflint: --config path does not exist: '$configPath'"
    exit 64
}

if ($args -contains '--init') {
    exit 0
}

if ($args -contains '--format' -or $args -contains '--format=json') {
    # Empty issues array — Invoke-AvmTerraformLint parses this as a pass.
    Write-Output '{"issues":[]}'
    exit 0
}

Write-Error "stub tflint: unhandled args '$($args -join ' ')'"
exit 64
