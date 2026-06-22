function Invoke-AvmBicepCheckPolicy {
    <#
    .SYNOPSIS
        Run policy checks against a Bicep module.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmCheckPolicy when the
        module context is Ecosystem='bicep'. The canonical implementation
        invokes PSRule.Rules.Azure in-process against the compiled ARM
        JSON of the module's main.bicep, normalises the rule output into
        a structured Issue collection, and returns a pass/fail summary.
        That is a substantial follow-on slice; the engine is
        intentionally stubbed for the PoC.

        Track the work via the bicep-check-policy slice in
        docs/avm-consolidation-plan.md.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Reserved for symmetry with the terraform engine.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        Issues. (When implemented.)
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

    throw [AvmConfigurationException]::new(
        "Bicep policy check is not yet wired: the in-process PSRule.Rules.Azure invocation is the next bicep-check-policy slice. Track it in docs/avm-consolidation-plan.md.")
}
