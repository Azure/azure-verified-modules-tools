function Invoke-AvmBicepTransform {
    <#
    .SYNOPSIS
        Regenerate README + test scaffolding for a Bicep module.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmTransform when the
        module context is Ecosystem='bicep'. The canonical implementation
        replaces Set-AVMModule.ps1 from the legacy AVM tooling: it
        re-runs the README generator (via the future Invoke-AvmBicepDocs
        ARM-walker) and rewrites the standard tests/e2e scaffolding.
        Both pieces are substantial follow-on slices, so this engine is
        intentionally stubbed for the PoC.

        Track the work via the bicep-transform slice in
        docs/avm-consolidation-plan.md.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Reserved for symmetry with the terraform engine.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Changed. (When implemented.)
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
            "Invoke-AvmBicepTransform requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $null = $AllowPathFallback

    throw [AvmConfigurationException]::new(
        "Bicep transform is not yet wired: the Set-AVMModule.ps1 README + tests scaffolding regenerator is the next bicep-transform slice. Track it in docs/avm-consolidation-plan.md.")
}
