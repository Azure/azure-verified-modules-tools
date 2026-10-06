function Invoke-AvmCheckPolicy {
    <#
    .SYNOPSIS
        Run policy checks against the resolved module.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> PSRule.Rules.Azure against tokenized defaults and
                          waf-aligned tests, with required and advisory baselines
          - terraform  -> Conftest with APRL and AVMSEC bundles

        The ecosystem is determined by Get-AvmModuleContext, which honours
        the .avm/context.psd1 override file and the -Ecosystem filter.
        Bicep policy checks use packaged ps-rule.yaml and .ps-rule/ assets
        under Resources/bicep/psrule. PSRule 2.9.0 and
        PSRule.Rules.Azure 1.47.0 must be installed separately. Set
        TEST_SUBSCRIPTION_IDS (the first entry is used) or
        VALIDATE_SUBSCRIPTION_ID, VALIDATE_TENANT_ID,
        VALIDATE_MANAGEMENT_GROUP_ID (or ARM_MGMTGROUP_ID), TOKEN_NAMEPREFIX,
        and localToken_* variables for tokens used by the selected tests.
        Missing inputs or uninspectable results fail rather than skip.

        Routed by the dispatcher: 'avm check policy'.

    .PARAMETER Path
        Working directory whose enclosing module to check. Defaults to
        the current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER ThrottleLimit
        Maximum number of independent Terraform examples to evaluate at once.
        Defaults to four. Bicep policy checks ignore this value.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery check that otherwise stops the command when a
        newer Avm.Authoring version is available. Writes a warning once.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, Issues.

    .EXAMPLE
        avm check policy

    .EXAMPLE
        Invoke-AvmCheckPolicy -Path C:\repos\my-bicep-module -Ecosystem bicep
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [ValidateRange(1, 32)]
        [int] $ThrottleLimit = 4,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $context = Get-AvmModuleContextInternal -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            Invoke-AvmBicepCheckPolicy -Context $context -AllowPathFallback:$AllowPathFallback
        }
        'terraform' {
            Invoke-AvmTerraformCheckPolicy `
                -Context $context `
                -AllowPathFallback:$AllowPathFallback `
                -ThrottleLimit $ThrottleLimit
        }
        default {
            throw [AvmContextException]::new(
                "Cannot run policy check: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
