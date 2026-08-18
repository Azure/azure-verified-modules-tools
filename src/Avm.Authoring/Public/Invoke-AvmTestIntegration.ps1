function Invoke-AvmTestIntegration {
    <#
    .SYNOPSIS
        Run the module's integration test tier (terraform test against
        tests/integration/).

    .DESCRIPTION
        Terraform-only test tier. Resolves the enclosing module via
        Get-AvmModuleContext, then runs 'terraform test' against the
        module's tests/integration/ directory through
        Invoke-AvmTerraformTestSuite -Tier integration.

        Unlike the bare 'avm test' verb (which is the cheap, offline
        'terraform validate' build pass wired into pre-commit), this tier
        executes real 'terraform test' HCL run blocks. Integration tests
        typically provision real Azure resources, so they need cloud
        credentials at runtime (for example an authenticated 'az' session
        or ARM_* environment variables). Authentication is left to
        terraform and its providers; this verb performs no preflight.

        Modules that ship no tests/integration/*.tftest.hcl report Status
        'skipped' with RunsTotal = 0 rather than a pass, so an absent tier can
        never look like a green one.

        This verb is a standalone command; it needs credentials, so it is NOT
        part of the 'avm pre-commit' or 'avm pr-check' gauntlets.

        Routed by the dispatcher: 'avm test integration'.

    .PARAMETER Path
        Working directory whose enclosing module to test. Defaults to the
        current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'. Bicep modules are
        rejected: the integration test tier is terraform-only.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER NoInit
        Skip the auto 'terraform init -backend=false -upgrade -test-directory=tests/integration'
        step, which otherwise always runs.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, RunsTotal, RunsPassed, RunsFailed, Issues.

    .EXAMPLE
        avm test integration

    .EXAMPLE
        Invoke-AvmTestIntegration -Path C:\repos\terraform-azurerm-avm-res-foo
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
            Invoke-AvmTerraformTestSuite -Context $context -Tier 'integration' -AllowPathFallback:$AllowPathFallback -NoInit:$NoInit
        }
        default {
            throw [AvmNotSupportedException]::new(
                "avm test integration is a terraform-only tier; the resolved module ecosystem is '$($context.Ecosystem)'. Bicep integration-test tiers are not implemented.")
        }
    }
}
