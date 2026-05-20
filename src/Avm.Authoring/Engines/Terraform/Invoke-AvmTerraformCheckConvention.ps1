function Invoke-AvmTerraformCheckConvention {
    <#
    .SYNOPSIS
        Run convention checks against a Terraform module.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmCheckConvention when
        the module context is Ecosystem='terraform'. The canonical
        implementation invokes 'grept run' against the pinned grept
        policy bundle. The pinned bundle asset and the grept binary
        itself are not yet wired into tools.lock.psd1, so this engine
        is intentionally stubbed for the PoC.

        Track the work via the terraform-check-convention slice in
        docs/avm-consolidation-plan.md.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool (for 'grept', when added to
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
            "Invoke-AvmTerraformCheckConvention requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $null = $AllowPathFallback

    throw [AvmConfigurationException]::new(
        "Terraform convention check is not yet wired: the 'grept run' invocation against the pinned grept-policies bundle (plus the grept entry in tools.lock.psd1 and the pinned policy assets) is the next terraform-check-convention slice. Track it in docs/avm-consolidation-plan.md.")
}
