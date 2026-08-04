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
        'terraform validate' build pass), this tier executes real
        'terraform test' HCL run blocks. Modules that ship no
        tests/unit/*.tftest.hcl report Status 'skipped' with RunsTotal = 0
        rather than a pass, so an absent tier can never look like a green one.

        This tier is credential-free by design, so it runs as part of the
        'avm pr-check' gauntlet. It is deliberately NOT part of 'avm
        pre-commit', which stays fast enough for a commit hook.

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
        Status, FilesProcessed, RunsTotal, RunsPassed, RunsFailed, Issues.

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

        [switch] $NoInit,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'terraform' {
            Invoke-AvmTerraformTestSuite -Context $context -Tier 'unit' -AllowPathFallback:$AllowPathFallback -NoInit:$NoInit
        }
        default {
            throw [AvmNotSupportedException]::new(
                "avm test unit is a terraform-only tier; the resolved module ecosystem is '$($context.Ecosystem)'. Bicep unit-test tiers are not implemented.")
        }
    }
}
