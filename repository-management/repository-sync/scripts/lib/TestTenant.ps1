#Requires -Version 7.4

. (Join-Path $PSScriptRoot '..' '..' '..' 'shared' 'TestTenant.ps1')
. (Join-Path $PSScriptRoot 'RetryHelpers.ps1')
. (Join-Path $PSScriptRoot 'TerraformOperations.ps1')

function Assert-AvmBamiRepositorySyncRunContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [bool] $PlanOnly)

    $manualBranchPreview = $PlanOnly -and
        $env:GITHUB_EVENT_NAME -ceq 'workflow_dispatch' -and
        $env:GITHUB_REF -cmatch '^refs/heads/[^\r\n]+$'
    if ($env:GITHUB_ACTIONS -cne 'true' -or
        $env:GITHUB_REPOSITORY -cne 'Azure/azure-verified-modules-tools' -or
        ($env:GITHUB_REF -cne 'refs/heads/main' -and -not $manualBranchPreview)) {
        throw [System.InvalidOperationException]::new(
            'BAMI repository sync requires trusted Azure/azure-verified-modules-tools main in GitHub Actions, except for manual plan-only branch previews.')
    }
}

function Resolve-AvmRepositorySyncFederationContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyString()] [string] $RepositoryId = $env:GITHUB_REPOSITORY_ID)

    if ($env:GITHUB_ACTIONS -cne 'true' -or
        $env:GITHUB_REPOSITORY -cne 'Azure/azure-verified-modules-tools' -or
        $env:GITHUB_REPOSITORY_ID -cnotmatch '^[1-9][0-9]*$' -or
        $RepositoryId -cne $env:GITHUB_REPOSITORY_ID) {
        throw [System.InvalidOperationException]::new('Validation federation requires the trusted tools repository and its positive GitHub Actions repository ID.')
    }
    $toolsRepository = Invoke-RepositoryGitHubApi -Endpoint 'repos/Azure/azure-verified-modules-tools'
    if ($null -eq $toolsRepository -or
        $toolsRepository.full_name -cne 'Azure/azure-verified-modules-tools' -or
        $toolsRepository.fork -ne $false -or
        $toolsRepository.owner.login -cne 'Azure' -or
        [string]$toolsRepository.id -cne $RepositoryId -or
        [string]$toolsRepository.owner.id -cnotmatch '^[1-9][0-9]*$') {
        throw [System.InvalidOperationException]::new('GitHub did not confirm the trusted tools repository and its immutable ID.')
    }
    return [pscustomobject]@{
        RepositoryId = $RepositoryId
        OrganizationId = [string]$toolsRepository.owner.id
    }
}

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
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $RepositoryOwnerId,
        [Parameter(Mandatory)] [string] $RepositorySyncRepositoryId
    )

    if ($RepositoryOwnerId -cnotmatch '^[1-9][0-9]*$' -or $RepositorySyncRepositoryId -cnotmatch '^[1-9][0-9]*$') {
        throw [System.ArgumentException]::new('Candidate validation federation requires positive GitHub organization and tools repository IDs.')
    }
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
    $validationCredentialAddress = 'module.azure.azapi_resource.validation_federated_credential'
    $allowed = @(
        'module.azure.azapi_resource.identity',
        'module.azure.azapi_resource.identity_role_assignment',
        'module.azure.azuread_group_member.example',
        'module.azure.azapi_resource.identity_federated_credentials["pr-check"]',
        'module.azure.azapi_resource.identity_federated_credentials["integration-test"]',
        'module.azure.azapi_resource.identity_federated_credentials["examples-test"]',
        $validationCredentialAddress
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
    $credential = @($resources | Where-Object { $_['address'] -ceq $validationCredentialAddress })[0]['values']
    if ($credential -isnot [System.Collections.IDictionary] -or
        $credential['body'] -isnot [System.Collections.IDictionary] -or
        $credential['body']['properties'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Candidate validation federation must have complete credential properties.')
    }
    $credentialProperties = $credential['body']['properties']
    $audiences = @($credentialProperties['audiences'])
    if ($credential['type'] -cne 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview' -or
        $credential['name'] -cne "$name-avm-validation" -or
        ($null -ne $credential['parent_id'] -and
            $credential['parent_id'] -cne "$parentId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name") -or
        $credentialProperties['issuer'] -cne 'https://token.actions.githubusercontent.com' -or
        $audiences.Count -ne 1 -or $audiences[0] -cne 'api://AzureADTokenExchange' -or
        $credentialProperties['subject'] -cne "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositorySyncRepositoryId}:environment:avm-validation") {
        throw [System.InvalidOperationException]::new('Candidate validation federation must target only the tools repository environment and the existing BAMI identity.')
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

function Write-AvmBamiIdentityPlanSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan,
        [Parameter(Mandatory)] [object] $Repository,
        [Parameter(Mandatory)] [string] $TenantId
    )

    $resources = @(Get-AvmTerraformPlannedResource -Module $Plan['planned_values']['root_module'])
    $readField = {
        param(
            [AllowNull()] [System.Collections.IDictionary] $Resource,
            [System.Collections.IDictionary] $Change,
            [string] $Path
        )

        $value = if ($Resource) { $Resource['values'] } else { $null }
        $sensitive = if ($Resource) { $Resource['sensitive_values'] } else { $null }
        $afterSensitive = $Change['after_sensitive']
        $unknown = $Change['after_unknown']
        foreach ($segment in $Path.Split('.')) {
            if ($value -is [System.Collections.IDictionary]) { $value = $value[$segment] }
            else { $value = $null }
            if ($sensitive -is [System.Collections.IDictionary]) { $sensitive = $sensitive[$segment] }
            if ($afterSensitive -is [System.Collections.IDictionary]) { $afterSensitive = $afterSensitive[$segment] }
            if ($unknown -is [System.Collections.IDictionary]) { $unknown = $unknown[$segment] }
        }
        if ($sensitive -eq $true -or $afterSensitive -eq $true) { return '[redacted: sensitive]' }
        if ($unknown -eq $true) { return '[unknown until apply]' }
        if ($null -eq $value) { return '[not present in plan]' }
        if ($value -is [string]) { return $value }
        if ($Path -ceq 'body.properties.audiences' -and $value -is [array] -and
            @($value | Where-Object { $_ -isnot [string] }).Count -eq 0) {
            return ,$value
        }
        return '[unavailable: expected a string or string array]'
    }
    $fields = [ordered]@{
        'module.azure.azapi_resource.identity' = [ordered]@{
            type = 'type'
            name = 'name'
            parent_id = 'parent_id'
            id = 'id'
            tenant_id = 'output.properties.tenantId'
            client_id = 'output.properties.clientId'
            principal_id = 'output.properties.principalId'
        }
        'module.azure.azapi_resource.identity_role_assignment' = [ordered]@{
            type = 'type'
            parent_id = 'parent_id'
            roleDefinitionId = 'body.properties.roleDefinitionId'
            principalId = 'body.properties.principalId'
            principalType = 'body.properties.principalType'
            conditionVersion = 'body.properties.conditionVersion'
            condition = 'body.properties.condition'
        }
        'module.azure.azuread_group_member.example' = [ordered]@{
            group_object_id = 'group_object_id'
            member_object_id = 'member_object_id'
        }
    }
    $federationFields = [ordered]@{
        type = 'type'
        name = 'name'
        parent_id = 'parent_id'
        issuer = 'body.properties.issuer'
        audiences = 'body.properties.audiences'
        subject = 'body.properties.subject'
    }
    foreach ($environment in @('pr-check', 'integration-test', 'examples-test')) {
        $fields['module.azure.azapi_resource.identity_federated_credentials["' + $environment + '"]'] = $federationFields
    }
    $fields['module.azure.azapi_resource.validation_federated_credential'] = $federationFields
    $summaryResources = @(
        foreach ($address in $fields.Keys) {
            $resource = @($resources | Where-Object { $_['address'] -ceq $address })[0]
            $changes = @($Plan['resource_changes'] | Where-Object { $_ -and $_['address'] -ceq $address })
            $change = if ($changes.Count -eq 1) { $changes[0]['change'] } else { @{} }
            $actions = @($change['actions'])
            $entry = [ordered]@{
                address = $address
                actions = if ($actions.Count -gt 0 -and @($actions | Where-Object {
                            $_ -isnot [string] -or $_ -cnotin @('no-op', 'create', 'update')
                        }).Count -eq 0) { ,$actions } else { '[unavailable: missing or ambiguous actions]' }
            }
            foreach ($field in $fields[$address].Keys) {
                $entry[$field] = & $readField -Resource $resource -Change $change -Path $fields[$address][$field]
            }
            $entry
        }
    )
    $groupAddress = 'module.azure.data.azuread_group.entra_readers'
    $groups = @($resources | Where-Object { $_['address'] -ceq $groupAddress })
    $group = if ($groups.Count -eq 1) { $groups[0] } else { $null }
    $groupChanges = @($Plan['resource_changes'] | Where-Object { $_ -and $_['address'] -ceq $groupAddress })
    $groupChange = if ($groupChanges.Count -eq 1) { $groupChanges[0]['change'] } else { @{} }
    $summary = [ordered]@{
        repository = $Repository.full_name
        repository_id = [string]$Repository.id
        repository_owner_id = [string]$Repository.owner.id
        expected_tenant_id = $TenantId
        directory_readers_group = & $readField -Resource $group -Change $groupChange -Path 'display_name'
        resources = $summaryResources
    }
    Write-Information -MessageData ("BAMI candidate identity plan summary:`n" + (ConvertTo-Json -InputObject $summary -Depth 6)) `
        -Tags 'AvmBamiIdentityPlanSummary' -InformationAction Continue
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
        [Parameter(Mandatory)] [string] $RepositorySyncRepositoryId,
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
    Assert-AvmBamiRepositorySyncRunContext -PlanOnly $PlanOnly
    $toolsContext = Resolve-AvmRepositorySyncFederationContext -RepositoryId $RepositorySyncRepositoryId
    $repo = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository"
    if ($repo.full_name -cne $Repository -or $repo.fork -or $repo.id -le 0 -or
        [string]$repo.owner.id -cne $toolsContext.OrganizationId -or $repo.owner.login -cne 'Azure') {
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
            repository_sync_repository_id = $toolsContext.RepositoryId
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
        Assert-AvmBamiIdentityPlan -Plan $plan -Settings $settings -Repository $Repository `
            -RepositoryOwnerId $toolsContext.OrganizationId -RepositorySyncRepositoryId $toolsContext.RepositoryId
        Write-AvmBamiIdentityPlanSummary -Plan $plan -Repository $repo -TenantId $settings['TEST_BAMI_TENANT_ID']
        if ($PlanOnly -and @($plan['resource_changes'] | Where-Object {
                    $_ -and $_['address'] -ceq 'module.azure.azapi_resource.validation_federated_credential' -and
                    $_['change']['actions'] -notcontains 'no-op'
                }).Count -gt 0) {
            return [pscustomobject]@{ Status = 'PendingCandidateIdentity'; StateKey = $stateKey; ConsumerSettings = $null }
        }
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
