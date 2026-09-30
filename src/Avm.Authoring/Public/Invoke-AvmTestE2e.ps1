function Invoke-AvmTestE2e {
    <#
    .SYNOPSIS
        Run Bicep isolated deployments or Terraform example end-to-end tests.

    .DESCRIPTION
        Bicep tests are discovered under tests/e2e/**/main.test.bicep.
        Eligible resource-group templates run in a new, uniquely named and
        tagged disposable group per example. ARM validate and what-if must
        succeed, and what-if must predict only creations within that group,
        before a deployment is allowed. Successful ARM provisioning is
        verified from the deployment response. Case-local *.Tests.ps1 Pester
        assertions then run in a child process with TestInputData containing
        DeploymentOutputs (ARM properties.outputs) and ModuleTestFolderPath.
        The group is deleted after success or failure, but only after its
        ownership tag and subscription are verified; failed cleanup is
        reported with the group name.

        Subscription, management-group and tenant templates require an
        explicit subscription and tenant; management-group templates also
        require the ID of an existing test management group. The selected
        Azure CLI account and management-group target are checked, but the
        caller must select an authorized nonproduction target and identity.
        No subscription, tenant or management group is provisioned or deleted.
        Only unassigned policy definitions, policy-set definitions, role
        definitions, and empty run-tagged subscription resource groups may
        be created, along with inspectable inline same-scope deployments
        using literal Incremental mode and only reviewed inline properties.
        ARM 2.0 symbolic resources are inspected under the same allowlist;
        only the exact outputs-only AVM telemetry template may be empty.
        Cross-scope, linked, scripted, assignment, alias and other resource
        types are rejected. A Create-only, expanded what-if prediction,
        preflight nonexistence, run-unique name, recorded deployment operation,
        and live resource identity must all agree before deletion. Failed
        ownership or deletion leaves the case failed with CleanupPending IDs
        and stops subsequent examples. Deployment history is retained.
        This narrow subset does not replace the registry's full test lifecycle.
        Use 'avm test integration' to validate and preview unsupported scopes
        or resources without deploying them. Tokens and additional ARM
        parameters are staged in temporary JSON files without editing source.

        Bicep AssertionResults distinguish optional absent assertions
        (Status 'not-present', deployment-only pass) from passing assertions
        (Status 'pass'). An authored suite fails its example if it has no
        passing tests or any failed, skipped, inconclusive, filtered, or
        setup-failed tests. Pester is stopped after 30 minutes so cleanup
        still runs if authored tests hang.

        Terraform walks runnable examples/ and runs init, apply,
        idempotency plan and destroy against a real backend.

        Both ecosystems require cloud credentials at runtime. No e2e run
        belongs in the local pre-commit gate.

        An example directory can opt out of the e2e run by containing a
        '.e2eignore' marker file. Modules that ship no runnable example report
        Status 'skipped' rather than a pass, so an absent tier can never look
        like a green one.

        Use -Example to select one or more cases. -List emits JSON names
        without resolving tools, credentials or a subscription.

        For Terraform only, an apply that fails on region or SKU capacity is
        destroyed and retried up to -MaxRetry times. The idempotency check is
        never retried. Bicep examples never automatically retry deployment.

        This verb is a standalone command; it needs credentials, so it is NOT
        part of the 'avm pre-commit' or 'avm pr-check' gauntlets.

        Routed by the dispatcher: 'avm test e2e'.

    .PARAMETER Path
        Working directory whose enclosing module to test. Defaults to the
        current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER Example
        Restrict the run to named examples. Bicep accepts a test-case folder
        leaf or a root-relative path; Terraform accepts an examples/ folder.
        Missing, ambiguous or ignored explicit selections are errors.

    .PARAMETER List
        Emit a JSON array of runnable example paths (Bicep) or folder names
        (Terraform), excluding .e2eignore. No Azure or tool access is needed.

    .PARAMETER MaxRetry
        Terraform-only transient apply retry budget, default 2. Bicep never
        retries a destructive deployment automatically.

    .PARAMETER Recurse
        Bicep-only: include nested module test scopes.

    .PARAMETER SubscriptionId
        Bicep-only: explicit subscription GUID for resource-group deployment
        or higher-scope Azure CLI account selection; ambient defaults are not used.

    .PARAMETER TenantId
        Bicep-only: explicit tenant GUID required for subscription,
        management-group and tenant deployments. The selected account must
        match it. Tenant-root write permissions are not assumed.

    .PARAMETER ManagementGroupId
        Bicep-only: existing management-group name required for management-group
        deployments. This command never creates or deletes that group.

    .PARAMETER Location
        Bicep-only: location for disposable groups and higher-scope deployment
        metadata.

    .PARAMETER ResourceGroupPrefix
        Bicep-only: required when resource-group examples are selected. A new
        unique disposable group is deleted after its example.

    .PARAMETER TokenFile
        Bicep-only: JSON object of token names and string values, relative to
        the module root or absolute. Scope IDs have explicit parameters.
        Higher-scope cases receive generated avmE2eRunId, avmE2eSuffix, and
        a default namePrefix; a custom namePrefix must produce run-unique
        resource names, for example using #_avmE2eSuffix_#.

    .PARAMETER Tokens
        Bicep-only: direct PowerShell hashtable instead of -TokenFile.

    .PARAMETER ParameterFile
        Bicep-only: existing ARM JSON parameter file copied to temporary
        storage and token-substituted, relative to the module root or absolute.

    .PARAMETER Parameters
        Bicep-only: direct PowerShell hashtable instead of -ParameterFile.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Issues. Bicep also reports RunsTotal,
        RunsPassed, RunsFailed, RunsSkipped, AssertionResults (per deployed
        example), CleanupPending and WhatIfChanges.

    .EXAMPLE
        avm test e2e

    .EXAMPLE
        avm test e2e -MaxRetry 0

    .EXAMPLE
        avm test e2e --example example-a

    .EXAMPLE
        avm test e2e --list

    .EXAMPLE
        Invoke-AvmTestE2e -Path C:\repos\terraform-azurerm-avm-res-foo

    .EXAMPLE
        avm test e2e --ecosystem bicep --list

    .EXAMPLE
        avm test e2e --subscription-id 00000000-0000-0000-0000-000000000001 --location westus --resource-group-prefix avm-e2e --token-file test-tokens.json

    .EXAMPLE
        Invoke-AvmTestE2e -Path C:\repos\bicep-module -Example defaults -SubscriptionId $testSubscriptionId -TenantId $testTenantId -ManagementGroupId $testManagementGroupId -Location westus
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

        [string] $ResourceGroupPrefix,

        [string] $TokenFile,

        [Alias('AdditionalTokens')]
        [System.Collections.IDictionary] $Tokens = @{},

        [string] $ParameterFile,

        [System.Collections.IDictionary] $Parameters = @{},

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($List) {
        $context = Get-AvmModuleContextInternal -Path $Path -Ecosystem $Ecosystem
    }
    else {
        Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
        $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem
    }

    switch ($context.Ecosystem) {
        'bicep' {
            if ($PSBoundParameters.ContainsKey('MaxRetry')) {
                throw [AvmConfigurationException]::new(
                    '-MaxRetry is only supported for Terraform e2e tests.')
            }
            $bicepInput = @{
                Context             = $context
                AllowPathFallback   = $AllowPathFallback
                Example             = $Example
                List                = $List
                Recurse             = $Recurse
                SubscriptionId      = $SubscriptionId
                TenantId            = $TenantId
                ManagementGroupId   = $ManagementGroupId
                Location            = $Location
                ResourceGroupPrefix = $ResourceGroupPrefix
                TokenFile           = $TokenFile
                Tokens              = $Tokens
                ParameterFile       = $ParameterFile
                Parameters          = $Parameters
            }
            if ($List) {
                Invoke-AvmBicepTestE2e @bicepInput
            }
            elseif ($PSCmdlet.ShouldProcess(
                    "$($context.Root) in subscription $SubscriptionId",
                    'Deploy Bicep tests and remove verified owned resources')) {
                Invoke-AvmBicepTestE2e @bicepInput -Confirm:$false -WhatIf:$false
            }
            else {
                Invoke-AvmBicepTestE2e @bicepInput -WhatIf
            }
        }
        'terraform' {
            if ($Recurse -or $PSBoundParameters.ContainsKey('SubscriptionId') -or
                $PSBoundParameters.ContainsKey('TenantId') -or
                $PSBoundParameters.ContainsKey('ManagementGroupId') -or
                $PSBoundParameters.ContainsKey('Location') -or
                $PSBoundParameters.ContainsKey('ResourceGroupPrefix') -or
                $PSBoundParameters.ContainsKey('TokenFile') -or
                $PSBoundParameters.ContainsKey('Tokens') -or
                $PSBoundParameters.ContainsKey('ParameterFile') -or
                $PSBoundParameters.ContainsKey('Parameters') -or
                $PSBoundParameters.ContainsKey('WhatIf') -or
                $PSBoundParameters.ContainsKey('Confirm')) {
                throw [AvmConfigurationException]::new(
                    'Bicep scope, token, parameter and ShouldProcess options are not supported for Terraform e2e tests.')
            }
            Invoke-AvmTerraformTestE2e -Context $context -AllowPathFallback:$AllowPathFallback -Example $Example -List:$List -MaxRetry $MaxRetry
        }
        default {
            throw [AvmContextException]::new(
                "Cannot run e2e tests: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
