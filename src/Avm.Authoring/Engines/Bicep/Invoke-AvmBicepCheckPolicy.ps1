function Invoke-AvmBicepCheckPolicy {
    <#
    .SYNOPSIS
        Run policy checks against a Bicep module.

    .DESCRIPTION
        Policy evaluation is not yet implemented. Report a failing,
        structured diagnostic rather than allowing pr-check to skip this
        required stage. The registry's PSRule checks use tokenized
        defaults and waf-aligned tests with two required and two advisory
        baselines; checking main.json alone would not provide parity.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Accepted for dispatcher compatibility.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        RequiredBaselines, AdvisoryBaselines, and Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmBicepCheckPolicy requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $null = $AllowPathFallback

    $required = @('Azure.Pillar.Reliability', 'CB.AVM.WAF.Security')
    $advisory = @('Azure.Default', 'Azure.Pillar.Security')

    return [pscustomobject][ordered]@{
        Engine            = 'bicep'
        Tool              = 'PSRule.Rules.Azure (not run)'
        ToolPath          = $null
        ToolSource        = 'not-run'
        Status            = 'fail'
        RequiredBaselines = $required
        AdvisoryBaselines = $advisory
        Issues            = @(
            [pscustomobject][ordered]@{
                File     = '.'
                Line     = 0
                Column   = 0
                Severity = 'error'
                Code     = 'avm.bicep.psrule-incomplete'
                Message  = 'PSRule policy coverage is incomplete: tokenized defaults and waf-aligned test sources must run Azure.Pillar.Reliability and CB.AVM.WAF.Security (required), plus Azure.Default and Azure.Pillar.Security (advisory). Keep the registry PSRule jobs until this is implemented.'
            }
        )
    }
}
