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
        Bicep policy checks use packaged ps-rule.yaml and rules/ assets
        under Resources/bicep/psrule. Exact PSRule and PSRule.Rules.Azure
        versions, including pinned dependencies and repository overrides,
        are resolved and prepared by the shared managed-tool installer. Set
        VALIDATE_SUBSCRIPTION_IDS or the TEST_SUBSCRIPTION_IDS alias. The first
        entry matching the exact module path in the required root
        .reserved-test-subscriptions.json map is used; unmapped modules use
        General, including untagged entries. Pool variables precede secrets.
        VALIDATE_SUBSCRIPTION_ID is a fallback only for General without a pool.
        Set VALIDATE_TENANT_ID,
        VALIDATE_MANAGEMENT_GROUP_ID (or ARM_MGMTGROUP_ID), TOKEN_NAMEPREFIX,
        and localToken_* variables for tokens used by the selected tests.
        Missing inputs or uninspectable results fail rather than skip.

        Terraform checks Azure authentication after pre.ps1 and .env loading,
        before init/plan. Supply ARM_* credentials (including a subscription)
        or an authenticated Azure CLI on PATH with an enabled subscription.
        CLI subscription and tenant IDs are passed only to child processes;
        the check never signs in or changes the selected CLI account.
        Providers still validate credentials and resource permissions.

        Terraform post-hook failure or interrupted cleanup retains recovery
        staging beneath the AVM cache (AVM_HOME/cache when overridden). The
        warning identifies the local path; it can contain sensitive state,
        plans, and environment files and must not be uploaded. Recover fixture
        resources before manually removing retained staging. Successful cleanup
        removes staging even when planning or policy evaluation fails.
        The original error remains terminating. When both evaluation and the
        post hook fail, Exception.Data['AvmPolicyPostError'] retains the post
        ErrorRecord; Exception.Data['AvmPolicyStagePath'] identifies staging.

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

    .PARAMETER Example
        Bicep-only exact module-relative main.test.bicep paths under tests/e2e,
        including child modules. Omit to select defaults and waf-aligned tests.
        Unmatched paths fail before evaluation.

    .PARAMETER Baseline
        Bicep-only subset of Azure.Pillar.Reliability, CB.AVM.WAF.Security,
        Azure.Default and Azure.Pillar.Security. Required and advisory
        outcomes are unchanged. Omit to run all four baselines.

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

    .EXAMPLE
        avm check policy --example tests/e2e/defaults/main.test.bicep --baseline Azure.Pillar.Reliability
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

        [ValidateNotNullOrEmpty()]
        [string[]] $Example,

        [ValidateNotNullOrEmpty()]
        [string[]] $Baseline,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $context = Get-AvmModuleContextInternal -Path $Path -Ecosystem $Ecosystem
    $selection = @{}
    foreach ($name in @('Example', 'Baseline')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $selection[$name] = $PSBoundParameters[$name]
        }
    }

    switch ($context.Ecosystem) {
        'bicep' {
            Invoke-AvmBicepCheckPolicy -Context $context -AllowPathFallback:$AllowPathFallback @selection
        }
        'terraform' {
            if ($selection.Count -gt 0) {
                throw [AvmConfigurationException]::new(
                    '-Example and -Baseline are only supported for Bicep policy checks.')
            }
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
