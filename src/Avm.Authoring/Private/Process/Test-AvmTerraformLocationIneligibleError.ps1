function Test-AvmTerraformLocationIneligibleError {
    <#
    .SYNOPSIS
        Identify Azure rejecting a region that is not accepting new customers.

    .DESCRIPTION
        Requires both the RequestDisallowedByAzure code and the
        aka.ms/locationineligible link, so other RequestDisallowedByAzure,
        policy, and authorization denials do not match.

    .PARAMETER Output
        Terraform error output to classify.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Output
    )

    return ($Output -match '\bRequestDisallowedByAzure\b') -and ($Output -match '\baka\.ms/locationineligible\b')
}
