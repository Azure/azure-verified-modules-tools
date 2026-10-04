function Invoke-AvmTestE2e {
    <#
    .SYNOPSIS
        Run Bicep or Terraform deployment tests with ordinary cleanup.

    .DESCRIPTION
        Bicep discovers tests/e2e/**/main.test.bicep and compiles temporary
        ARM templates without editing source. Existing Azure PowerShell and
        Azure CLI sign-ins must identify the same account, tenant, cloud and
        selected subscription. Required Az modules are checked, not installed.
        Native ARM validation and deployment support resource-group,
        subscription, management-group and tenant scope, including nested
        and cross-scope module deployments. Select authorized test targets:
        resources created or updated by the test can be removed afterwards.

        Successful deployments run their case-local Pester assertions, then
        post.ps1, then native cleanup adapted from the registry workflow.
        Assertions and hooks run in the same PowerShell process to retain
        process-only sign-ins. Caller or workflow cancellation applies;
        no separate-process timeout or credential transfer is used. A failed
        assertion or hook still runs ordinary cleanup. An authored assertion
        suite must have passing tests and no failed, skipped, filtered,
        inconclusive or setup-failed tests. Absent suites are 'not-present'.

        Cleanup follows recorded Create deployment operations recursively,
        not Read references or a subscription-wide inventory. Resource-group
        cases use a unique group and verified ownership tag. Attempt IDs and
        required post-removal metadata are saved in an atomic local JSON file
        before submission or removal. The state contains no credentials,
        parameters or outputs, and survives temporary-template removal.
        Incomplete cleanup reports pending IDs and stops subsequent cases.
        The reaper is a fallback, not the normal cleanup mechanism.

        All runs the complete lifecycle. Deploy retains resources and state
        for a separate Complete call after caller-owned sign-in renewal.
        Complete requires matching direct case/module source, assertion files
        and post hook, plus explicit subscription/tenant. It rereads outputs by
        exact deployment ID and never submits a deployment. The source check
        does not fingerprint every imported helper or dependency.
        Interrupted completion must use avm test cleanup rather than replaying
        authored scripts. Actions callers may upload state as an artifact;
        recovery requires that the upload finished before runner loss.

        KeepResources runs assertions but deliberately skips post.ps1 and
        cleanup. The saved file can later be passed to avm test cleanup,
        which does not need the checkout and never runs assertions or hooks.

        Terraform runs init, apply, idempotency plan and destroy for runnable
        examples/. MaxRetry controls Terraform transient apply retries.
        No deployment tests belong in avm pr-check or the local build gate.
        Listing does not resolve tools or credentials. An absent tier is
        'skipped', not a pass; .e2eignore excludes a case.

    .PARAMETER Path
        Module directory, or an enclosing context. Defaults to the current location.
    .PARAMETER Ecosystem
        Explicit ecosystem, or auto-detection.
    .PARAMETER AllowPathFallback
        Accept a PATH tool only when it reports the lock-pinned version.
    .PARAMETER Example
        Select case names or root-relative Bicep paths. Explicit ignored,
        absent or ambiguous selections are errors.
    .PARAMETER List
        Return a JSON array of runnable example names without cloud access.
    .PARAMETER MaxRetry
        Terraform-only transient apply retry budget, default two retries.
    .PARAMETER Recurse
        Bicep-only: include child-module test cases.
    .PARAMETER SubscriptionId
        Bicep-only: explicit test subscription GUID. Ambient defaults are not used.
    .PARAMETER TenantId
        Bicep-only: explicit tenant GUID required for every deployment scope.
    .PARAMETER ManagementGroupId
        Bicep-only: existing target management-group name for that scope.
    .PARAMETER Location
        Bicep deployment-metadata location, fixed across regional retries.
        Also the placement fallback for explicitly global resource types.
    .PARAMETER ResourceLocation
        Pin Bicep resource placement. Must agree with parameter/token locations.
    .PARAMETER ResourceGroupPrefix
        Required for resource-group Bicep cases; up to 57 safe name characters.
    .PARAMETER TokenFile
        JSON string-valued tokens, relative to the module root or absolute.
        Mutually exclusive with Tokens. Explicit scope parameters own scope tokens.
    .PARAMETER Tokens
        Bicep token dictionary instead of TokenFile. Generated avmE2eRunId and
        avmE2eSuffix tokens provide a unique default namePrefix.
    .PARAMETER ParameterFile
        ARM JSON parameter file, preserving values and vault references.
        Mutually exclusive with Parameters; source is not changed.
    .PARAMETER Parameters
        Bicep parameter values. SecureString values remain in memory.
        Explicit values or files take precedence over CI inputs.
    .PARAMETER UseCiInputs
        Opt into AVM_CI_VARIABLES and AVM_CI_SECRETS JSON, localToken_*,
        TOKEN_NAMEPREFIX and deprecated CI_KEY_VAULT_NAME inputs. CI secrets
        beat variables; CI_ aliases beat CI__ aliases within a source.
        Missing explicit IDs may use VALIDATE_SUBSCRIPTION_ID,
        VALIDATE_TENANT_ID and TEST_SUBSCRIPTION_IDS. Nothing logs in.
    .PARAMETER TestSubscriptionIds
        Optional Bicep JSON array of id/name subscription objects. Cases are
        balanced over a stable seeded ordering, independent of JSON ordering.
    .PARAMETER SubscriptionSelectionSeed
        Shared nonnegative seed for deterministic subscription ordering.
    .PARAMETER SubscriptionJobIndex
        Nonnegative initial case index for round-robin subscription selection.
    .PARAMETER Phase
        Bicep All (default), Deploy, or Complete for caller-owned sign-in renewal.
    .PARAMETER CleanupStatePath
        Optional new state file for one selected case. Complete requires an
        existing file and the explicitly matching subscription and tenant.
    .PARAMETER KeepResources
        Bicep-only: run assertions but retain resources, skipping post and cleanup.
    .PARAMETER DeploymentRetryLimit
        Bicep total submission attempts, one to three. Only confirmed failure
        or exact preflight rejection can retry; unknown outcomes never resubmit.
    .PARAMETER ValidationRetryLimit
        Bicep total regional validation attempts, one to three. Only wholly
        regional failures relocate; explicit pins, global resources and
        resource-group cases do not relocate. Deployment stays in the validated region.
    .PARAMETER SkipModuleVersionCheck
        Skip the advisory module-version check.

    .OUTPUTS
        Engine result with Status, Issues and run counts. Bicep also returns
        Phase, AssertionResults, PostResults, CleanupPending, CleanupDeferred
        and CleanupStatePaths. Deployment outputs and parameters are not returned.

    .EXAMPLE
        avm test e2e --list
    .EXAMPLE
        avm test e2e --subscription-id $testSubscriptionId --tenant-id $testTenantId --location eastus --resource-group-prefix avm-e2e
    .EXAMPLE
        avm test e2e --example defaults --subscription-id $testSubscriptionId --tenant-id $testTenantId --location eastus --phase Deploy --cleanup-state-path cleanup.json
    .EXAMPLE
        avm test e2e --phase Complete --cleanup-state-path cleanup.json --subscription-id $testSubscriptionId --tenant-id $testTenantId
    .EXAMPLE
        avm test e2e --max-retry 0 --ecosystem terraform
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,
        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',
        [switch] $AllowPathFallback,
        [AllowEmptyCollection()]
        [string[]] $Example = @(),
        [switch] $List,
        [ValidateRange(0, 10)]
        [int] $MaxRetry = 2,
        [switch] $Recurse,
        [string] $SubscriptionId,
        [string] $TenantId,
        [string] $ManagementGroupId,
        [string] $Location,
        [string] $ResourceLocation,
        [string] $ResourceGroupPrefix,
        [string] $TokenFile,
        [Alias('AdditionalTokens')]
        [System.Collections.IDictionary] $Tokens = @{},
        [string] $ParameterFile,
        [System.Collections.IDictionary] $Parameters = @{},
        [switch] $UseCiInputs,
        [string] $TestSubscriptionIds,
        [ValidateRange(0, [int]::MaxValue)]
        [int] $SubscriptionSelectionSeed = 0,
        [ValidateRange(0, [int]::MaxValue)]
        [int] $SubscriptionJobIndex = 0,
        [ValidateSet('All', 'Deploy', 'Complete')]
        [string] $Phase = 'All',
        [string] $CleanupStatePath,
        [switch] $KeepResources,
        [ValidateRange(1, 3)]
        [int] $DeploymentRetryLimit = 3,
        [ValidateRange(1, 3)]
        [int] $ValidationRetryLimit = 3,
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $List) {
        Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    }
    $context = Get-AvmModuleContextInternal -Path $Path -Ecosystem $Ecosystem
    $bicepOptions = @(
        'Recurse', 'SubscriptionId', 'TenantId', 'ManagementGroupId', 'Location',
        'ResourceLocation', 'ResourceGroupPrefix', 'TokenFile', 'Tokens', 'ParameterFile', 'Parameters',
        'UseCiInputs', 'TestSubscriptionIds', 'SubscriptionSelectionSeed', 'SubscriptionJobIndex',
        'Phase', 'CleanupStatePath', 'KeepResources', 'DeploymentRetryLimit', 'ValidationRetryLimit'
    )
    switch ($context.Ecosystem) {
        'bicep' {
            if ($PSBoundParameters.ContainsKey('MaxRetry')) {
                throw [AvmConfigurationException]::new('-MaxRetry is only supported for Terraform e2e tests.')
            }
            $inputOptions = @{ Context = $context; AllowPathFallback = $AllowPathFallback; Example = $Example; List = $List }
            foreach ($name in $bicepOptions) {
                if ($PSBoundParameters.ContainsKey($name)) { $inputOptions[$name] = $PSBoundParameters[$name] }
            }
            if ($List) {
                Invoke-AvmBicepTestE2e @inputOptions
            }
            elseif ($PSCmdlet.ShouldProcess($context.Root, "Run Bicep e2e phase $Phase in explicit test targets")) {
                Invoke-AvmBicepTestE2e @inputOptions -Confirm:$false -WhatIf:$false
            }
            else {
                Invoke-AvmBicepTestE2e @inputOptions -WhatIf
            }
        }
        'terraform' {
            foreach ($name in $bicepOptions + @('WhatIf', 'Confirm')) {
                if ($name -eq 'Recurse' -and -not $Recurse) { continue }
                if ($PSBoundParameters.ContainsKey($name)) {
                    throw [AvmConfigurationException]::new(
                        'Bicep scope, input, phase, cleanup and ShouldProcess options are not supported for Terraform e2e tests.')
                }
            }
            Invoke-AvmTerraformTestE2e -Context $context -AllowPathFallback:$AllowPathFallback `
                -Example $Example -List:$List -MaxRetry $MaxRetry
        }
        default {
            throw [AvmContextException]::new("Cannot run e2e tests: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
