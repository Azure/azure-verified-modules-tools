function Test-AvmRepositorySyncManaged {
    <#
    .SYNOPSIS
        Report whether repository sync already manages a repository.
    .DESCRIPTION
        Repository sync creates the repository-level 'Azure Verified Modules'
        ruleset and sets global-rulesets-opt-out permanently, so the ruleset
        shows that sync owns the property.
    .PARAMETER Repository
        Repository as owner/name.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $rulesets = @(Invoke-AvmGitHubApi -Endpoint "repos/$Repository/rulesets?includes_parents=false&per_page=100")
    return @($rulesets | Where-Object {
            $_ -is [System.Collections.IDictionary] -and $_['name'] -ceq 'Azure Verified Modules'
        }).Count -gt 0
}
