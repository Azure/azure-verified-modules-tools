function Invoke-AvmTerraformCheckPolicy {
    <#
    .SYNOPSIS
        Run policy checks against a Terraform module.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmCheckPolicy when the
        module context is Ecosystem='terraform'. The canonical
        implementation invokes 'conftest test' against the pinned APRL +
        AVMSEC policy bundles. The pinned bundle asset and the conftest
        binary itself are not yet wired into tools.lock.psd1, so this
        engine is intentionally stubbed for the PoC.

        Track the work via the terraform-check-policy slice in
        docs/avm-consolidation-plan.md.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool (for 'conftest', when added to
        tools.lock.psd1).

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

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformCheckPolicy requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $null = $AllowPathFallback

    throw [AvmConfigurationException]::new(
        "Terraform policy check is not yet wired: the conftest invocation against the APRL + AVMSEC bundles (plus the conftest entry in tools.lock.psd1 and the pinned policy assets) is the next terraform-check-policy slice. Track it in docs/avm-consolidation-plan.md.")
}
