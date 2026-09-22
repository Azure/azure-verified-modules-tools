function Test-AvmTerraformTransientError {
    <#
    .SYNOPSIS
        Identify known Terraform capacity, quota, and region availability errors.

    .DESCRIPTION
        Matches availability-specific wording, not broad codes such as
        OperationNotAllowed. E2E callers may add AVM_E2E_RETRY_PATTERN.

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

    $patterns = @(
        'SkuNotAvailable'
        'Capacity Restrictions'
        'is currently not available in location'
        'sku_selector found no deployable VM size'
        'Allocation ?Failed'
        'results in exceeding approved'
        'LocationNotAvailableForResourceGroup'
        'currently experiencing high demand in .*? region'
    )

    if (-not $BuiltInOnly -and -not [string]::IsNullOrWhiteSpace($env:AVM_E2E_RETRY_PATTERN)) {
        $patterns += $env:AVM_E2E_RETRY_PATTERN
    }

    return [regex]::IsMatch(
        $Output,
        ($patterns -join '|'),
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}
