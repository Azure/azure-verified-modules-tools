function Invoke-AvmBicepDocs {
    <#
    .SYNOPSIS
        Generate or refresh the README documentation for a Bicep module.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmDocs when the module
        context is Ecosystem='bicep'. The canonical implementation is a
        deliberate redesign: instead of porting Set-ModuleReadMe.ps1 into
        an in-process ARM-JSON walker (the approach used during the
        slice 1-4f spike, reverted on 2026-05-26 because it duplicated
        work that belongs in a separate, focused CLI command), the new
        plan is to wire avm docs to a dedicated bicep documentation CLI.
        That CLI is not yet designed; this engine is intentionally
        stubbed until it is. The previous walker implementation lives
        on commit 17f63cf if its diff is ever useful as reference.

        Track the new docs slice in docs/avm-consolidation-plan.md.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Reserved for symmetry with the terraform engine; will be passed
        through to Resolve-AvmTool once the new docs CLI is added to
        tools.lock.psd1.

    .PARAMETER OutputFile
        README path (relative to module root) to inject into. Reserved
        for symmetry with the terraform engine and the Invoke-AvmDocs
        dispatcher signature; defaults to 'README.md'.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Changed. (When implemented.)
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Noun mirrors the avm CLI verb (avm docs).')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [string] $OutputFile = 'README.md'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmBicepDocs requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $null = $AllowPathFallback
    $null = $OutputFile

    throw [AvmConfigurationException]::new(
        "Bicep docs generation is being redesigned as a separate CLI command. The previous ARM-JSON walker (commit 17f63cf) has been removed pending the new design. Track the new docs slice in docs/avm-consolidation-plan.md.")
}
