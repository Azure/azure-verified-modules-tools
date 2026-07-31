function Invoke-AvmTestUnit {
    <#
    .SYNOPSIS
        Run the module's unit test tier (terraform test against tests/unit/).

    .DESCRIPTION
        Terraform-only test tier. Resolves the enclosing module via
        Get-AvmModuleContext, then runs 'terraform test' against the
        module's tests/unit/ directory through
        Invoke-AvmTerraformTestSuite -Tier unit.

        Unlike the bare 'avm test' verb (which is the cheap, offline
        'terraform validate' build pass wired into pre-commit), this tier
        executes real 'terraform test' HCL run blocks. Modules that ship no
        tests/unit/*.tftest.hcl report a clean pass with FilesProcessed = 0.

        This verb is a standalone command; it is NOT part of the offline
        pre-commit / pr-check chains, which keep the validate-only 'test'.

        Routed by the dispatcher: 'avm test unit'.

    .PARAMETER Path
        Working directory whose enclosing module to test. Defaults to the
        current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'. Bicep modules are
        rejected: the unit test tier is terraform-only.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER NoInit
        Skip the auto 'terraform init -backend=false -test-directory=tests/unit'
        step, which otherwise always runs.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Issues.

    .EXAMPLE
        avm test unit

    .EXAMPLE
        Invoke-AvmTestUnit -Path C:\repos\terraform-azurerm-avm-res-foo
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [switch] $NoInit
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'terraform' {
            Invoke-AvmTerraformTestSuite -Context $context -Tier 'unit' -AllowPathFallback:$AllowPathFallback -NoInit:$NoInit
        }
        default {
            throw [AvmConfigurationException]::new(
                "avm test unit is a terraform-only tier; the resolved module ecosystem is '$($context.Ecosystem)'. Bicep unit-test tiers are not implemented.")
        }
    }
}
