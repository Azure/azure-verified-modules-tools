function Invoke-AvmTerraformTransform {
    <#
    .SYNOPSIS
        Regenerate README + test scaffolding for a Terraform module.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmTransform when the
        module context is Ecosystem='terraform'. The canonical
        implementation runs 'mapotf transform --mptf-dir <configs>
        --tf-dir <module>' followed by 'mapotf clean-backup', mirroring
        the existing Terraform module authoring flow. The pinned
        mapotf-configs bundle and the mapotf binary itself are not yet
        wired into tools.lock.psd1, so this engine is intentionally
        stubbed for the PoC.

        Track the work via the terraform-transform slice in
        docs/avm-consolidation-plan.md.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool (for 'mapotf', when added to
        tools.lock.psd1).

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

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformTransform requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $null = $AllowPathFallback

    throw [AvmConfigurationException]::new(
        "Terraform transform is not yet wired: the mapotf transform + clean-backup engine (plus the mapotf entry in tools.lock.psd1 and the pinned mapotf-configs asset) is the next terraform-transform slice. Track it in docs/avm-consolidation-plan.md.")
}
