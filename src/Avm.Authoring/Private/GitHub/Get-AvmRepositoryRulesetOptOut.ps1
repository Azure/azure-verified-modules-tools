function Get-AvmRepositoryRulesetOptOut {
    <#
    .SYNOPSIS
        Read a repository's global-rulesets-opt-out custom property.
    .DESCRIPTION
        Returns 'true', 'false', or $null when the property has no value. The
        enterprise property exempts a repository from organization rulesets such
        as azure-production-ruleset.
    .PARAMETER Repository
        Repository as owner/name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $properties = @(Invoke-AvmGitHubApi -Endpoint "repos/$Repository/properties/values")
    foreach ($property in $properties) {
        if ($property -isnot [System.Collections.IDictionary]) {
            throw [System.IO.InvalidDataException]::new("GitHub returned invalid custom properties for $Repository.")
        }
    }
    $matching = @($properties | Where-Object { $_['property_name'] -ceq 'global-rulesets-opt-out' })
    if ($matching.Count -gt 1) {
        throw [System.IO.InvalidDataException]::new("GitHub returned duplicate ruleset opt-out properties for $Repository.")
    }
    $value = if ($matching.Count -eq 1) { $matching[0]['value'] } else { $null }
    if ($null -ne $value -and ($value -isnot [string] -or $value -cnotin @('true', 'false'))) {
        throw [System.IO.InvalidDataException]::new("GitHub returned an invalid global-rulesets-opt-out value for $Repository.")
    }
    return $value
}
