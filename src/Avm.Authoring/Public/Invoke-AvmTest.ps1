function Invoke-AvmTest {
    <#
    .SYNOPSIS
        Build Bicep sources or validate Terraform examples under $Path.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepTest      ('bicep build --stdout' per file)
          - terraform  -> Invoke-AvmTerraformTest  ('terraform validate -json' per example with auto-init)

        The ecosystem is determined by Get-AvmModuleContext, which honours
        the .avm/context.psd1 override file and the -Ecosystem filter.

        This verb covers the cheap build-validation pass and runs no
        tests: it reports FilesProcessed (Bicep sources or direct Terraform
        example configuration files) and
        carries no run counts. The real test tiers are the separate
        'avm test unit', 'avm test integration' and 'avm test e2e'
        verbs, which execute 'terraform test' and report
        RunsTotal/RunsPassed/RunsFailed. In the gauntlets this verb is
        the step named 'validate' for that reason.

        Terraform includes .e2eignore examples and warns when the root module
        or an immediate modules/ configuration is not reached by a local
        example. Coverage gaps do not fail validation. No examples is skipped.

        Routed by the dispatcher: 'avm test'.

    .PARAMETER Path
        Working directory whose enclosing module to test. Defaults to the
        current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER NoInit
        Terraform-only: skip each example's 'terraform init -backend=false
        -upgrade' step and use its existing initialization. Module coverage is
        not assessed with this switch and reports a warning. Ignored for Bicep.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Issues.

    .EXAMPLE
        avm test

    .EXAMPLE
        Invoke-AvmTest -Path C:\repos\my-module -Ecosystem bicep
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
        'bicep' {
            $null = $NoInit  # -NoInit is terraform-only; harmless for bicep.
            Invoke-AvmBicepTest -Context $context -AllowPathFallback:$AllowPathFallback
        }
        'terraform' {
            Invoke-AvmTerraformTest -Context $context -AllowPathFallback:$AllowPathFallback -NoInit:$NoInit
        }
        default {
            throw [AvmContextException]::new(
                "Cannot test: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
