function Invoke-AvmBicepPolicyBaseline {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $StageRoot,

        [Parameter(Mandatory)]
        [string] $InputPath,

        [Parameter(Mandatory)]
        [string] $OptionPath,

        [Parameter(Mandatory)]
        [string] $RulePath,

        [Parameter(Mandatory)]
        [string] $Baseline
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Push-Location -LiteralPath $StageRoot
    try {
        return @(Invoke-PSRule -InputPath $InputPath -Format File -As Detail `
                -Outcome All -Module PSRule.Rules.Azure -Baseline $Baseline `
                -Option $OptionPath -Path $RulePath -ErrorAction Stop `
                -WarningAction SilentlyContinue)
    }
    finally {
        Pop-Location
    }
}
