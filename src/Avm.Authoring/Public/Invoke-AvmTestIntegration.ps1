function Invoke-AvmTestIntegration {
    <#
    .SYNOPSIS
        Run Bicep ARM validation/what-if or Terraform integration tests.

    .DESCRIPTION
        For Bicep, compiles tests/e2e/**/main.test.bicep, substitutes
        #_name_# tokens only in temporary ARM JSON, then runs Azure CLI
        deployment validate and what-if. Requires an explicit subscription
        ID. Resource-group validation requires an existing group; this tier
        never creates one. An .e2eignore marker excludes an example.
        -Example selects one or more examples; -Recurse includes nested
        module scopes. Missing or entirely ignored tests report 'skipped'.

        For Terraform, runs 'terraform test' against tests/integration/
        through Invoke-AvmTerraformTestSuite -Tier integration.

        Unlike the bare build-only 'avm test' verb, this tier needs Azure
        credentials at runtime. Terraform integration tests can provision
        resources; Bicep validation and what-if do not deploy them.

        Modules that ship no tests/integration/*.tftest.hcl report Status
        'skipped' with RunsTotal = 0 rather than a pass, so an absent tier can
        never look like a green one. Existing targets that execute no runs or
        skip selected runs fail rather than reporting a pass.

        This verb is a standalone command; it needs credentials, so it is NOT
        part of the 'avm pre-commit' or 'avm pr-check' gauntlets.

        Recognized capacity and region-ineligible failures are retried only
        after Terraform confirms completed test teardown. Assertions,
        authorization, configuration, cleanup, and unknown errors are not
        retried. Each new invocation recreates Terraform's test fixtures, so a
        fixture that selects a random region can choose another region.

        Routed by the dispatcher: 'avm test integration'.

    .PARAMETER Path
        Working directory whose enclosing module to test. Defaults to the
        current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER NoInit
        Terraform-only: skip the automatic terraform init step.

    .PARAMETER MaxRetry
        Terraform-only retry budget for transient capacity failures (0-10).
        Defaults to 2; Bicep ARM validation does not retry.

    .PARAMETER SubscriptionId
        Bicep-only: explicit subscription GUID. Ambient defaults are never used.

    .PARAMETER ResourceGroupName
        Bicep-only: name of an existing group for resource-group-scope tests.

    .PARAMETER ManagementGroupId
        Bicep-only: management group for management-group-scope tests.

    .PARAMETER Location
        Bicep-only: deployment metadata location for subscription, management
        group and tenant tests.

    .PARAMETER TokenFile
        Bicep-only: JSON object mapping token names to string values. Relative
        paths resolve under the module root. Subscription and management
        group IDs are supplied by their dedicated parameters, not this file.

    .PARAMETER Tokens
        Bicep-only: direct PowerShell hashtable alternative to -TokenFile.

    .PARAMETER ParameterFile
        Bicep-only: existing ARM JSON parameter file. Relative paths resolve
        under the module root. A temporary copy receives token substitution.

    .PARAMETER Parameters
        Bicep-only: direct PowerShell hashtable alternative to -ParameterFile.
        Values are written to a temporary ARM parameter file, not command-line
        arguments.

    .PARAMETER Example
        Bicep-only: select a case by folder name or root-relative path.
        An ignored, missing or ambiguous explicit selection is an error.

    .PARAMETER Recurse
        Bicep-only: include nested module test scopes.

    .PARAMETER Operation
        Bicep-only: Both (default), Validate or WhatIf.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, RunsTotal, RunsPassed, RunsFailed, Issues. Bicep
        additionally reports IgnoredFiles, RunsSkipped and WhatIfChanges.

    .EXAMPLE
        avm test integration

    .EXAMPLE
        avm test integration --max-retry 0

    .EXAMPLE
        Invoke-AvmTestIntegration -Path C:\repos\terraform-azurerm-avm-res-foo

    .EXAMPLE
        avm test integration --subscription-id 00000000-0000-0000-0000-000000000001 --resource-group-name existing-test-rg --token-file test-tokens.json
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

        [ValidateRange(0, 10)]
        [int] $MaxRetry = 2,

        [string] $SubscriptionId,

        [string] $ResourceGroupName,

        [string] $ManagementGroupId,

        [string] $Location,

        [string] $TokenFile,

        [Alias('AdditionalTokens')]
        [System.Collections.IDictionary] $Tokens = @{},

        [string] $ParameterFile,

        [System.Collections.IDictionary] $Parameters = @{},

        [AllowEmptyCollection()]
        [string[]] $Example = @(),

        [switch] $Recurse,

        [ValidateSet('Both', 'Validate', 'WhatIf')]
        [string] $Operation = 'Both',

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem `
        -SkipModuleVersionCheck:$SkipModuleVersionCheck

    switch ($context.Ecosystem) {
        'bicep' {
            if ($NoInit -or $PSBoundParameters.ContainsKey('MaxRetry')) {
                throw [AvmConfigurationException]::new(
                    '-NoInit and -MaxRetry are only supported for Terraform integration tests.')
            }
            Invoke-AvmBicepTestIntegration -Context $context -AllowPathFallback:$AllowPathFallback `
                -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
                -ManagementGroupId $ManagementGroupId -Location $Location `
                -TokenFile $TokenFile -Tokens $Tokens `
                -ParameterFile $ParameterFile -Parameters $Parameters -Example $Example `
                -Recurse:$Recurse -Operation $Operation
        }
        'terraform' {
            if ($PSBoundParameters.ContainsKey('SubscriptionId') -or
                $PSBoundParameters.ContainsKey('ResourceGroupName') -or
                $PSBoundParameters.ContainsKey('ManagementGroupId') -or
                $PSBoundParameters.ContainsKey('Location') -or
                $PSBoundParameters.ContainsKey('TokenFile') -or
                $PSBoundParameters.ContainsKey('Tokens') -or
                $PSBoundParameters.ContainsKey('ParameterFile') -or
                $PSBoundParameters.ContainsKey('Parameters') -or
                $PSBoundParameters.ContainsKey('Example') -or
                $Recurse -or $PSBoundParameters.ContainsKey('Operation')) {
                throw [AvmConfigurationException]::new(
                    'ARM scope, token, example and operation options are only supported for Bicep integration tests.')
            }
            Invoke-AvmTerraformTestSuite -Context $context -Tier 'integration' -AllowPathFallback:$AllowPathFallback -NoInit:$NoInit -MaxRetry $MaxRetry
        }
        default {
            throw [AvmContextException]::new(
                "Cannot run integration tests: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
