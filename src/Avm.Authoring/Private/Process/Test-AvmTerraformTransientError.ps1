function Test-AvmTerraformTransientError {
    <#
    .SYNOPSIS
        Identify known Terraform capacity, quota, and region availability errors.

    .DESCRIPTION
        Matches availability-specific wording, not broad codes such as
        OperationNotAllowed, plus the region-ineligible denial recognized by
        Test-AvmTerraformLocationIneligibleError. E2E callers may add
        AVM_E2E_RETRY_PATTERN.

    .PARAMETER Output
        Terraform error output to classify.

    .PARAMETER BuiltInOnly
        Ignore the E2E-specific custom pattern for integration test diagnostics.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Output,

        [switch] $BuiltInOnly
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $false
    }

    if (Test-AvmTerraformLocationIneligibleError -Output $Output) {
        return $true
    }

    $policy = Get-AvmTerraformRetryPolicy
    $patterns = @($policy['sharedMessagePatterns'])

    if (-not $BuiltInOnly) {
        foreach ($block in ($Output -split '\r?\n[ \t]*\r?\n')) {
            $allMatch = $true
            foreach ($pattern in $policy['e2eAllMessagePatterns']) {
                if ($block -notmatch $pattern) {
                    $allMatch = $false
                    break
                }
            }
            if ($allMatch) { return $true }
        }
        if (-not [string]::IsNullOrWhiteSpace($env:AVM_E2E_RETRY_PATTERN)) {
            $patterns += $env:AVM_E2E_RETRY_PATTERN
        }
    }

    return [regex]::IsMatch(
        $Output,
        ($patterns -join '|'),
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}
