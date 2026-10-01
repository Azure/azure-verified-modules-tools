function Set-AvmRepositoryRulesetOptOut {
    <#
    .SYNOPSIS
        Set a repository's global-rulesets-opt-out custom property and verify it.
    .PARAMETER Repository
        Repository as owner/name.
    .PARAMETER Value
        'true', 'false', or $null to clear the value.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Value
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($null -ne $Value -and ($Value -isnot [string] -or $Value -cnotin @('true', 'false'))) {
        throw [System.ArgumentException]::new('global-rulesets-opt-out must be the string true, false, or null.')
    }
    $description = if ($null -eq $Value) { 'unset' } else { $Value }
    if (-not $PSCmdlet.ShouldProcess($Repository, "Set global-rulesets-opt-out to $description")) {
        return
    }
    $body = @{ properties = @(@{ property_name = 'global-rulesets-opt-out'; value = $Value }) }
    $null = Invoke-AvmGitHubApi -Endpoint "repos/$Repository/properties/values" -Method PATCH -Body $body
    $current = Get-AvmRepositoryRulesetOptOut -Repository $Repository
    if ($current -cne $Value) {
        throw [System.InvalidOperationException]::new(
            "Could not verify global-rulesets-opt-out=$description for $Repository.")
    }
}
