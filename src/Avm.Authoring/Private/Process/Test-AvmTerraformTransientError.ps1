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

    return -not [string]::IsNullOrEmpty((Get-AvmTerraformRetryMode -Output $Output -BuiltInOnly:$BuiltInOnly))
}
