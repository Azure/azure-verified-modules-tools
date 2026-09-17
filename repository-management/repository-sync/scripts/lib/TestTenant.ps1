#Requires -Version 7.4

. (Join-Path $PSScriptRoot '..' '..' '..' 'shared' 'TestTenant.ps1')
. (Join-Path $PSScriptRoot 'RetryHelpers.ps1')
. (Join-Path $PSScriptRoot 'TerraformOperations.ps1')

function Resolve-RepositoryTestTenantSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $TestTenant,
        [System.Collections.IDictionary] $BamiValues = @{}
    )

    if ($TestTenant -isnot [string] -or $TestTenant -cnotin @('legacy', 'bami')) {
        throw [System.ArgumentException]::new('testTenant must be exactly legacy or bami.')
    }
    $settings = $null
    if ($TestTenant -ceq 'bami') {
        $settings = Get-AvmBamiSettings -Values $BamiValues
    }
    return [pscustomobject]@{ SelectedTestTenant = $TestTenant; TestTenant = $TestTenant; Status = 'Ready'; Settings = $settings }
}

function Get-AvmBamiIdentityStateKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $RepoId
    )

    $id = [guid]::Empty
    if (-not [guid]::TryParseExact($TenantId, 'D', [ref] $id) -or $id -eq [guid]::Empty -or
        $RepoId -cnotmatch '^avm-(res|ptn|utl)-[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw [System.ArgumentException]::new('Candidate state requires a tenant GUID and a canonical AVM repository ID.')
    }
    return "bami-identities/$($id.ToString())/$RepoId.tfstate"
}

function Get-AvmTerraformPlannedResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Module)

    if ($Module.Contains('resources')) {
        foreach ($resource in $Module['resources']) {
            $resource
        }
    }
    if ($Module.Contains('child_modules')) {
        foreach ($child in $Module['child_modules']) {
            Get-AvmTerraformPlannedResource -Module $child
        }
    }
}

function Assert-AvmBamiIdentityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [string] $Repository
    )

    if (($Plan.Contains('errored') -and $Plan['errored'] -ne $false) -or $Plan['planned_values'] -isnot [System.Collections.IDictionary] -or
        $Plan['planned_values']['root_module'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Candidate Terraform plan is incomplete or errored.')
    }
    foreach ($change in @($Plan['resource_changes'])) {
        if ($null -eq $change) { continue }
        if ($change['change']['actions'] -contains 'delete') {
            throw [System.InvalidOperationException]::new('Candidate identity plans must not delete or replace resources. Existing state is retained.')
        }
    }
    $resources = @(Get-AvmTerraformPlannedResource -Module $Plan['planned_values']['root_module'])
    $allowed = @(
        'module.azure.azapi_resource.identity',
        'module.azure.azapi_resource.identity_role_assignment',
        'module.azure.azuread_group_member.example',
        'module.azure.azapi_resource.identity_federated_credentials["pr-check"]',
        'module.azure.azapi_resource.identity_federated_credentials["integration-test"]',
        'module.azure.azapi_resource.identity_federated_credentials["examples-test"]'
    )
    $managed = @($resources | Where-Object { $_['mode'] -ceq 'managed' })
    $addresses = @($managed | ForEach-Object { $_['address'] } | Select-Object -Unique)
    if ($managed.Count -ne $allowed.Count -or $addresses.Count -ne $allowed.Count -or
        @($addresses | Where-Object { $_ -cnotin $allowed }).Count -gt 0) {
        throw [System.InvalidOperationException]::new('Candidate plan must contain only the complete dedicated repository identity, federation, and membership scope.')
    }
    $identities = @($resources | Where-Object { $_['address'] -ceq 'module.azure.azapi_resource.identity' })
    $roles = @($resources | Where-Object { $_['address'] -ceq 'module.azure.azapi_resource.identity_role_assignment' })
    if ($identities.Count -ne 1 -or $roles.Count -ne 1) {
        throw [System.InvalidOperationException]::new('Candidate plan must contain the dedicated repository identity and its role assignment.')
    }
    $parentId = "/subscriptions/$($Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'])/resourceGroups/$($Settings['TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME'])"
    $name = $Repository.Replace('/', '-').Replace('windows', 'w5s')
    if ($identities[0]['values']['parent_id'] -cne $parentId -or $identities[0]['values']['name'] -cne $name) {
        throw [System.InvalidOperationException]::new('Candidate identity is not scoped to the expected repository and BAMI resource group.')
    }
    $role = $roles[0]['values']
    $properties = $role['body']['properties']
    $owner = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
    $denied = @($owner, '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9', 'f58310d9-a9f6-439a-9e8d-f62e7b41a168') | Sort-Object
    if ($role['parent_id'] -cne "/providers/Microsoft.Management/managementGroups/$($Settings['TEST_BAMI_MANAGEMENT_GROUP_ID'])" -or
        $properties['roleDefinitionId'] -cne "/providers/Microsoft.Authorization/roleDefinitions/$owner" -or
        $properties['conditionVersion'] -cne '2.0' -or $properties['condition'] -isnot [string]) {
        throw [System.InvalidOperationException]::new('Candidate role assignment has an unexpected scope, role, or condition version.')
    }
    $condition = [regex]::Replace($properties['condition'], "('[^']*')|\s+", '$1').ToLowerInvariant()
    $sets = [regex]::Matches($condition, '\{([0-9a-f,-]+)\}')
    if ($sets.Count -ne 2) {
        throw [System.InvalidOperationException]::new('Candidate delegation must deny Owner, User Access Administrator, and RBAC Administrator on both write and delete.')
    }
    $normalizedSet = '{' + ($denied -join ',') + '}'
    foreach ($set in $sets) {
        $ids = @($set.Groups[1].Value.Split(',') | Sort-Object)
        if (($ids -join ',') -cne ($denied -join ',')) {
            throw [System.InvalidOperationException]::new('Candidate activation requires the reviewed Owner/UAA/RBAC Administrator delegation fix on both write and delete.')
        }
        $condition = $condition.Replace($set.Value, $normalizedSet)
    }
    $expected = @"
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}))OR(@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId]ForAnyOfAllValues:GuidNotEquals$normalizedSet))
AND
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}))OR(@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId]ForAnyOfAllValues:GuidNotEquals$normalizedSet))
"@
    if ($condition -cne [regex]::Replace($expected, "('[^']*')|\s+", '$1').ToLowerInvariant()) {
        throw [System.InvalidOperationException]::new('Candidate delegation condition does not match the required deny rules.')
    }
}

function ConvertTo-AvmBamiConsumerSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Identity,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [object] $Repository
    )

    $Settings = Get-AvmBamiSettings -Values $Settings
    $clientId = [guid]::Empty
    $expectedIdentity = "/subscriptions/$($Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'])/resourceGroups/$($Settings['TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME'])/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($Repository.full_name.Replace('/', '-').Replace('windows', 'w5s'))"
    if ($Identity['client_id'] -isnot [string] -or -not [guid]::TryParseExact($Identity['client_id'], 'D', [ref] $clientId) -or
        $clientId -eq [guid]::Empty -or $clientId.ToString() -in @($Settings['TEST_BAMI_CONTROLLER_CLIENT_ID'], $Settings['TEST_BAMI_BICEP_CLIENT_ID']) -or
        $Identity['tenant_id'] -ine $Settings['TEST_BAMI_TENANT_ID'] -or
        $Identity['identity_resource_id'] -ine $expectedIdentity -or
        $Identity['repository_id'] -cne [string]$Repository.id -or $Identity['repository_owner_id'] -cne [string]$Repository.owner.id) {
        throw [System.InvalidOperationException]::new('Candidate output is not a complete dedicated test identity for the expected tenant and repository; controller/Bicep identities cannot be used.')
    }
    return @{
        tenant_id = $Settings['TEST_BAMI_TENANT_ID']
        client_id = $clientId.ToString()
        controller_client_id = $Settings['TEST_BAMI_CONTROLLER_CLIENT_ID']
        bicep_client_id = $Settings['TEST_BAMI_BICEP_CLIENT_ID']
        admin_subscription_id = $Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID']
        persistent_subscription_id = $Settings['TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID']
        test_subscription_ids = ConvertFrom-AvmTestTenantJson -Json $Settings['TEST_BAMI_SUBSCRIPTION_IDS']
    }
}

function Invoke-AvmBamiIdentityTerraform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [hashtable] $Environment
    )

    $result = Invoke-RepositorySyncProcess -Command terraform -Arguments $Arguments `
        -WorkingDirectory $Root -EnvVars $Environment -TimeoutSec 1800
    if ($result.ExitCode -ne 0) {
        throw [System.InvalidOperationException]::new("Candidate Terraform $($Arguments[0]) failed; no state repair or automatic apply retry was attempted. $($result.StdErr)")
    }
    return $result.StdOut
}

function Invoke-AvmBamiRepositoryIdentity {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $RepoId,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $BamiValues,
        [Parameter(Mandatory)] [hashtable] $Backend,
        [Parameter(Mandatory)] [string] $Root,
        [string] $JobWorkflowRef = 'Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main',
        [string] $TemporaryRoot = [System.IO.Path]::GetTempPath(),
        [bool] $PlanOnly = $true
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $settings = Get-AvmBamiSettings -Values $BamiValues
    $stateKey = Get-AvmBamiIdentityStateKey -TenantId $settings['TEST_BAMI_TENANT_ID'] -RepoId $RepoId
    $state = Resolve-RepositorySyncStateConfiguration -Backend $Backend
    if ($Repository -cnotmatch ('^Azure/terraform-(azurerm|azure|azapi)-' + [regex]::Escape($RepoId) + '$')) {
        throw [System.ArgumentException]::new('Candidate identities are limited to the selected Azure AVM repository.')
    }
    $repo = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository"
    if ($repo.full_name -cne $Repository -or $repo.fork -or $repo.id -le 0 -or $repo.owner.id -le 0 -or $repo.owner.login -cne 'Azure') {
        throw [System.InvalidOperationException]::new('GitHub returned an unexpected candidate repository identity.')
    }
    if (-not $PSCmdlet.ShouldProcess($Repository, 'Prepare an isolated BAMI identity plan')) {
        return [pscustomobject]@{ Status = 'Preview'; StateKey = $stateKey; ConsumerSettings = $null }
    }
    $workspace = Join-Path $TemporaryRoot ('avm-bami-' + [guid]::NewGuid().ToString('N'))
    $null = [System.IO.Directory]::CreateDirectory($workspace)
    try {
        $variablesPath = Join-Path $workspace 'candidate.tfvars.json'
        $planPath = Join-Path $workspace 'candidate.tfplan'
        $variables = [ordered]@{
            tenant_id = $settings['TEST_BAMI_TENANT_ID']
            subscription_id = $settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID']
            controller_client_id = $settings['TEST_BAMI_CONTROLLER_CLIENT_ID']
            management_group_id = $settings['TEST_BAMI_MANAGEMENT_GROUP_ID']
            identity_resource_group_name = $settings['TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME']
            github_repository_owner = $repo.owner.login
            github_repository_name = $repo.name
            github_organization_id = [string]$repo.owner.id
            github_repository_id = [string]$repo.id
            github_job_workflow_ref = $JobWorkflowRef
        }
        [System.IO.File]::WriteAllText($variablesPath, (ConvertTo-Json -InputObject $variables -Depth 5), [System.Text.UTF8Encoding]::new($false))
        $environment = @{
            TF_DATA_DIR = Join-Path $workspace 'data'
            TF_IN_AUTOMATION = 'true'
            TF_INPUT = 'false'
            TF_CLI_ARGS = $null
            TF_CLI_ARGS_init = $null
            TF_CLI_ARGS_plan = $null
            TF_CLI_ARGS_apply = $null
            GH_TOKEN = $null
            ARM_TENANT_ID = $settings['TEST_BAMI_TENANT_ID']
            ARM_SUBSCRIPTION_ID = $settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID']
            ARM_CLIENT_ID = $settings['TEST_BAMI_CONTROLLER_CLIENT_ID']
            ARM_CLIENT_SECRET = $null
            ARM_CLIENT_CERTIFICATE_PATH = $null
            ARM_CLIENT_CERTIFICATE = $null
            ARM_ACCESS_KEY = $null
            ARM_SAS_TOKEN = $null
            ARM_USE_OIDC = 'true'
            ARM_USE_CLI = 'false'
            ARM_USE_MSI = 'false'
        }
        $init = @(
            'init', '-upgrade', '-input=false', '-no-color', '-reconfigure',
            "-backend-config=storage_account_name=$($state.StorageAccountName)",
            "-backend-config=container_name=$($state.ContainerName)",
            "-backend-config=key=$stateKey",
            "-backend-config=tenant_id=$($state.TenantId)",
            "-backend-config=subscription_id=$($state.SubscriptionId)",
            "-backend-config=client_id=$($state.ClientId)",
            '-backend-config=use_azuread_auth=true', '-backend-config=use_oidc=true',
            '-backend-config=use_cli=false', '-backend-config=use_msi=false', '-backend-config=lookup_blob_endpoint=false'
        )
        $null = Invoke-AvmBamiIdentityTerraform -Arguments $init -Root $Root -Environment $environment
        $null = Invoke-AvmBamiIdentityTerraform -Arguments @(
            'plan', '-input=false', '-no-color', '-lock-timeout=5m', "-var-file=$variablesPath", "-out=$planPath"
        ) -Root $Root -Environment $environment
        $planJson = Invoke-AvmBamiIdentityTerraform -Arguments @('show', '-json', $planPath) -Root $Root -Environment $environment
        $plan = ConvertFrom-Json -InputObject $planJson -AsHashtable -Depth 100
        Assert-AvmBamiIdentityPlan -Plan $plan -Settings $settings -Repository $Repository
        if ($PlanOnly) {
            $outputs = $plan['planned_values']['outputs']
            $identity = if ($outputs -and $outputs.Contains('test_identity')) { $outputs['test_identity']['value'] } else { $null }
            if ($null -eq $identity -or -not $identity.Contains('client_id') -or [string]::IsNullOrWhiteSpace($identity['client_id'])) {
                return [pscustomobject]@{ Status = 'PendingCandidateIdentity'; StateKey = $stateKey; ConsumerSettings = $null }
            }
        }
        else {
            if (-not $PSCmdlet.ShouldProcess($stateKey, 'Apply the verified candidate identity plan')) {
                return [pscustomobject]@{ Status = 'Preview'; StateKey = $stateKey; ConsumerSettings = $null }
            }
            $null = Invoke-AvmBamiIdentityTerraform -Arguments @(
                'apply', '-input=false', '-no-color', '-lock-timeout=5m', $planPath
            ) -Root $Root -Environment $environment
            $outputsJson = Invoke-AvmBamiIdentityTerraform -Arguments @('output', '-json') -Root $Root -Environment $environment
            $outputs = ConvertFrom-Json -InputObject $outputsJson -AsHashtable -Depth 30
            $identity = $outputs['test_identity']['value']
        }
        $consumerSettings = ConvertTo-AvmBamiConsumerSettings -Identity $identity -Settings $settings -Repository $repo
        return [pscustomobject]@{ Status = 'Ready'; StateKey = $stateKey; ConsumerSettings = $consumerSettings }
    }
    finally {
        Remove-Item -LiteralPath $workspace -Recurse -Force
    }
}
