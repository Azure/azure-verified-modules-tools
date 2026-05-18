function Invoke-AvmBicepDocs {
    <#
    .SYNOPSIS
        Generate README documentation for a Bicep module.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmDocs when the module
        context is Ecosystem='bicep'. The canonical implementation walks
        the compiled ARM JSON to surface parameters, outputs, and
        metadata, then injects the result into README.md between marker
        comments. That walker is a substantial follow-on slice
        (replaces Set-ModuleReadMe.ps1 from the legacy AVM tooling) and
        is intentionally stubbed here so the public verb dispatcher
        and engine plumbing can land first.

        Track the walker work via the bicep-docs slice in
        docs/avm-consolidation-plan.md.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Reserved for symmetry with the terraform engine. Pass-through
        for the future Resolve-AvmTool calls (none today since this is
        pure PowerShell + ARM JSON parsing).

    .PARAMETER OutputFile
        README path (relative to module root) to inject into. Defaults
        to 'README.md'.

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
        "Bicep docs is not yet wired: the ARM-JSON walker that replaces Set-ModuleReadMe.ps1 is the next bicep-docs slice. Track it in docs/avm-consolidation-plan.md.")
}
