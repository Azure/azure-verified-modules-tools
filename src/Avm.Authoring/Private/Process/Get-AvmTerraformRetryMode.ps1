function Get-AvmTerraformRetryMode {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Output,

        [switch] $BuiltInOnly
    )

    if ([string]::IsNullOrWhiteSpace($Output)) { return }
    $policy = Get-AvmTerraformRetryPolicy
    foreach ($rule in $policy['fresh']) {
        if ((-not $BuiltInOnly -or $rule['integration']) -and
            (Test-AvmTerraformRetryRule -Output $Output -Rule $rule)) { return 'Fresh' }
    }
    if (-not $BuiltInOnly) {
        foreach ($rule in $policy['inPlace']) {
            if (Test-AvmTerraformRetryRule -Output $Output -Rule $rule) { return 'InPlace' }
        }
        if (-not [string]::IsNullOrWhiteSpace($env:AVM_E2E_RETRY_PATTERN) -and
            $Output -match $env:AVM_E2E_RETRY_PATTERN) { return 'Fresh' }
    }
}
