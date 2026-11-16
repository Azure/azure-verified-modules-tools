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

    if (-not $BuiltInOnly) {
        if (-not (Get-Variable -Name AvmTerraformE2eRetryPatterns -Scope Script -ErrorAction Ignore)) {
            $root = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath @('..', 'Resources', 'terraform')
            $json = [System.IO.File]::ReadAllText((Join-Path $root 'e2e-retry-policy.json'))
            $schema = [System.IO.File]::ReadAllText((Join-Path $root 'e2e-retry-policy.schema.json'))
            if (-not (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)) {
                throw [AvmConfigurationException]::new('The Terraform E2E retry policy is invalid.')
            }
            $script:AvmTerraformE2eRetryPatterns = @(($json | ConvertFrom-Json -AsHashtable)['messagePatterns'])
        }
        $patterns += $script:AvmTerraformE2eRetryPatterns
        if (-not [string]::IsNullOrWhiteSpace($env:AVM_E2E_RETRY_PATTERN)) {
            $patterns += $env:AVM_E2E_RETRY_PATTERN
        }
    }

    return [regex]::IsMatch(
        $Output,
        ($patterns -join '|'),
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}
