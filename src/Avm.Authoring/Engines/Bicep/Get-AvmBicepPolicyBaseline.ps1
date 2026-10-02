function Get-AvmBicepPolicyBaseline {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Configuration,

        [Parameter(Mandatory)]
        [string] $Name
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $parameters = @{
        Module = 'PSRule.Rules.Azure'
        Path   = $Configuration.RulePath
        Option = $Configuration.Option
    }
    $found = @(Get-PSRuleBaseline @parameters -Name $Name -ErrorAction Stop)
    if ($found.Count -ne 1 -or $found[0].Name -cne $Name) {
        throw [AvmConfigurationException]::new(
            "Required Bicep PSRule baseline '$Name' is missing or ambiguous.")
    }
    $rules = @(Get-PSRule @parameters -Baseline $Name -ErrorAction Stop)
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($rule in $rules) {
        if ([string]::IsNullOrWhiteSpace([string]$rule.RuleName)) {
            throw [AvmConfigurationException]::new(
                "Bicep PSRule baseline '$Name' has a rule without a name.")
        }
        $null = $names.Add([string]$rule.RuleName)
    }
    if ($names.Count -eq 0) {
        throw [AvmConfigurationException]::new(
            "Bicep PSRule baseline '$Name' contains no available rules.")
    }
    return [pscustomobject]@{
        Name      = $Name
        RuleNames = $names
    }
}
