function Invoke-AvmBicepCheckConvention {
    <#
    .SYNOPSIS
        Run convention checks against a Bicep module.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmCheckConvention when
        the module context is Ecosystem='bicep'. The canonical
        implementation ports (or wraps) the ~500-line compliance Pester
        suite that lives in module.tests.ps1 in the legacy AVM tooling,
        scoped to a single module folder. That is a substantial
        follow-on slice; the engine is intentionally stubbed for the
        PoC.

        Track the work via the bicep-check-convention slice in
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
            "Invoke-AvmBicepCheckConvention requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $null = $AllowPathFallback

    throw [AvmConfigurationException]::new(
        "Bicep convention check is not yet wired: the module.tests.ps1 compliance suite port is the next bicep-check-convention slice. Track it in docs/avm-consolidation-plan.md.")
}
