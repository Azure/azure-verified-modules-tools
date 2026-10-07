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
    if ($TestTenant -ceq 'legacy') {
        throw [System.InvalidOperationException]::new('The legacy test tenant is retired. Normal repository sync requires testTenant bami.')
    }
    $settings = Get-AvmBamiSettings -Values $BamiValues
    return [pscustomobject]@{ SelectedTestTenant = $TestTenant; TestTenant = $TestTenant; Status = 'Ready'; Settings = $settings }
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

function Get-AvmTerraformPlanDataResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Plan)

    # Completed reads are in the refreshed prior state; planned values contain deferred reads.
    $priorState = $Plan['prior_state']
    if ($priorState -isnot [System.Collections.IDictionary] -or
        $priorState['values'] -isnot [System.Collections.IDictionary] -or
        $priorState['values']['root_module'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Candidate membership requires refreshed Terraform data-source evidence.')
    }
    foreach ($resource in @(Get-AvmTerraformPlannedResource -Module $priorState['values']['root_module'])) {
        if ($resource['mode'] -cne 'data') { continue }
        $changes = @($Plan['resource_changes'] | Where-Object { $_['address'] -ceq $resource['address'] })
        if ($changes.Count -gt 1 -or ($changes.Count -eq 1 -and
            ($changes[0]['mode'] -cne 'data' -or $changes[0]['type'] -cne $resource['type'] -or
                (@($changes[0]['change']['actions']) -join ',') -cne 'no-op'))) {
            throw [System.InvalidOperationException]::new("Candidate membership requires completed plan-time data reads; '$($resource['address'])' has a pending or ambiguous change.")
        }
        $resource
    }
}

function Test-AvmTerraformPlanUnknownField {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Change,
        [Parameter(Mandatory)] [string] $Path
    )

    $unknown = $Change['after_unknown']
    foreach ($segment in $Path.Split('.')) {
        if ($unknown -eq $true) { return $true }
        if ($unknown -isnot [System.Collections.IDictionary]) { return $false }
        $unknown = $unknown[$segment]
    }
    return $unknown -eq $true
}

function Get-AvmBamiOwnerAssignmentName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings
    )

    # Match Terraform's uuidv5("url", ...) assignment identifier.
    $namespace = [byte[]]@(0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8)
    $name = $Repository.Replace('/', '') + $Settings['TEST_BAMI_MANAGEMENT_GROUP_ID'] + $Settings['TEST_BAMI_TENANT_ID']
    $hash = [System.Security.Cryptography.SHA1]::HashData([byte[]]($namespace + [System.Text.Encoding]::UTF8.GetBytes($name)))
    $hash[6] = ($hash[6] -band 0x0f) -bor 0x50
    $hash[8] = ($hash[8] -band 0x3f) -bor 0x80
    $hex = [System.Convert]::ToHexString([byte[]]$hash[0..15]).ToLowerInvariant()
    return '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
}

function Assert-AvmBamiIdentityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $RepositoryId,
        [Parameter(Mandatory)] [string] $RepositoryOwnerId,
        [Parameter(Mandatory)] [string] $RepositorySyncRepositoryId,
        [string] $JobWorkflowRef = 'Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main',
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $EntraGroupNames,
        [ValidateSet('module.azure', 'module.bami[0]')] [string] $ModuleAddress = 'module.azure'
    )

    $Settings = Get-AvmBamiSettings -Values $Settings
    $EntraGroupNames = ConvertTo-AvmEntraGroupNames -Names $EntraGroupNames
    if ($RepositoryId -cnotmatch '^[1-9][0-9]*$' -or $RepositoryOwnerId -cnotmatch '^[1-9][0-9]*$' -or
        $RepositorySyncRepositoryId -cnotmatch '^[1-9][0-9]*$') {
        throw [System.ArgumentException]::new('Candidate federation requires positive GitHub repository, organization, and tools repository IDs.')
    }
    if (($Plan.Contains('errored') -and $Plan['errored'] -ne $false) -or $Plan['planned_values'] -isnot [System.Collections.IDictionary] -or
        $Plan['planned_values']['root_module'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Candidate Terraform plan is incomplete or errored.')
    }
    if ($Plan['resource_changes'] -isnot [System.Collections.IList]) {
        throw [System.InvalidOperationException]::new('Candidate Terraform plan must include complete resource changes.')
    }
    $resources = @(Get-AvmTerraformPlannedResource -Module $Plan['planned_values']['root_module'])
    $identityAddress = "$ModuleAddress.azapi_resource.identity"
    $validationCredentialAddress = "$ModuleAddress.azapi_resource.validation_federated_credential"
    $membershipNames = @{}
    foreach ($groupName in $EntraGroupNames) {
        $key = ConvertTo-Json -InputObject $groupName -Compress
        $membershipNames["$ModuleAddress.azuread_group_member.test_permissions[$key]"] = $groupName
    }
    $allowed = @(
        $identityAddress,
        "$ModuleAddress.azapi_resource.identity_federated_credentials[`"pr-check`"]",
        "$ModuleAddress.azapi_resource.identity_federated_credentials[`"integration-test`"]",
        "$ModuleAddress.azapi_resource.identity_federated_credentials[`"examples-test`"]",
        $validationCredentialAddress
    )
    $allowed += @($membershipNames.Keys)
    $managed = @($resources | Where-Object { $_['mode'] -ceq 'managed' })
    $addresses = @($managed | ForEach-Object { $_['address'] } | Select-Object -Unique)
    if ($managed.Count -ne $allowed.Count -or $addresses.Count -ne $allowed.Count -or
        @($addresses | Where-Object { $_ -cnotin $allowed }).Count -gt 0) {
        throw [System.InvalidOperationException]::new('Candidate plan must contain only the complete dedicated repository identity, federation, and membership scope.')
    }
    $changes = @{}
    foreach ($change in $Plan['resource_changes']) {
        if ($change -isnot [System.Collections.IDictionary] -or $change['address'] -isnot [string] -or
            $change['change'] -isnot [System.Collections.IDictionary] -or $changes.ContainsKey($change['address'])) {
            throw [System.InvalidOperationException]::new('Candidate plan contains missing or ambiguous resource changes.')
        }
        $changes[$change['address']] = $change
    }
    foreach ($resource in $managed) {
        $address = $resource['address']
        $type = if ($membershipNames.ContainsKey($address)) { 'azuread_group_member' } else { 'azapi_resource' }
        $change = $changes[$address]
        $actions = if ($null -ne $change) { @($change['change']['actions']) } else { @() }
        $permittedActions = if ($type -ceq 'azuread_group_member') { @('no-op', 'create', 'update', 'delete,create', 'create,delete') } else { @('no-op', 'create', 'update') }
        if ($resource['type'] -cne $type -or $resource['values'] -isnot [System.Collections.IDictionary] -or
            $null -eq $change -or $change['mode'] -cne 'managed' -or $change['type'] -cne $type -or
            ($actions -join ',') -cnotin $permittedActions) {
            throw [System.InvalidOperationException]::new('Candidate identity plans must not delete or replace required resources, or omit their changes.')
        }
    }
    $identity = @($managed | Where-Object { $_['address'] -ceq $identityAddress })[0]['values']
    $parentId = "/subscriptions/$($Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'])/resourceGroups/$($Settings['TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME'])"
    $name = $Repository.Replace('/', '-').Replace('windows', 'w5s')
    $identityId = "$parentId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name"
    if ($identity['parent_id'] -cne $parentId -or $identity['name'] -cne $name -or
        ($null -ne $identity['id'] -and $identity['id'] -ine $identityId) -or
        $identity['type'] -cne 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview') {
        throw [System.InvalidOperationException]::new('Candidate identity is not scoped to the expected repository and BAMI resource group.')
    }
    $dataResources = @(Get-AvmTerraformPlanDataResource -Plan $Plan)
    $azureContexts = @($dataResources | Where-Object { $_['address'] -ceq "$ModuleAddress.data.azapi_client_config.current" })
    $graphContexts = @($dataResources | Where-Object { $_['address'] -ceq "$ModuleAddress.data.azuread_client_config.current" })
    if ($azureContexts.Count -ne 1 -or $graphContexts.Count -ne 1 -or
        $azureContexts[0]['mode'] -cne 'data' -or $graphContexts[0]['mode'] -cne 'data' -or
        $azureContexts[0]['type'] -cne 'azapi_client_config' -or $graphContexts[0]['type'] -cne 'azuread_client_config' -or
        $azureContexts[0]['values'] -isnot [System.Collections.IDictionary] -or
        $graphContexts[0]['values'] -isnot [System.Collections.IDictionary] -or
        $azureContexts[0]['values']['tenant_id'] -isnot [string] -or
        $azureContexts[0]['values']['subscription_id'] -isnot [string] -or
        $graphContexts[0]['values']['tenant_id'] -isnot [string] -or
        $graphContexts[0]['values']['client_id'] -isnot [string] -or
        $azureContexts[0]['values']['tenant_id'] -ine $Settings['TEST_BAMI_TENANT_ID'] -or
        $azureContexts[0]['values']['subscription_id'] -ine $Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'] -or
        $graphContexts[0]['values']['tenant_id'] -ine $Settings['TEST_BAMI_TENANT_ID'] -or
        $graphContexts[0]['values']['client_id'] -ine $Settings['TEST_BAMI_CONTROLLER_CLIENT_ID']) {
        throw [System.InvalidOperationException]::new('Candidate membership requires verified Azure and Graph tenant/controller evidence.')
    }
    $controllerPrincipal = [guid]::Empty
    if ($graphContexts[0]['values']['object_id'] -isnot [string] -or
        -not [guid]::TryParseExact($graphContexts[0]['values']['object_id'], 'D', [ref] $controllerPrincipal) -or
        $controllerPrincipal -eq [guid]::Empty) {
        throw [System.InvalidOperationException]::new('Candidate membership requires a verified controller principal object ID.')
    }
    $principal = $null
    if ($identity['output'] -is [System.Collections.IDictionary] -and
        $identity['output']['properties'] -is [System.Collections.IDictionary]) {
        $principal = $identity['output']['properties']['principalId']
        if ($identity['output']['properties']['tenantId'] -ine $Settings['TEST_BAMI_TENANT_ID']) {
            throw [System.InvalidOperationException]::new('Candidate identity output must belong to the pinned BAMI tenant.')
        }
        $clientId = [guid]::Empty
        $client = $identity['output']['properties']['clientId']
        if ($client -isnot [string] -or -not [guid]::TryParseExact($client, 'D', [ref] $clientId) -or
            $clientId -eq [guid]::Empty -or
            $clientId.ToString() -in @($Settings['TEST_BAMI_CONTROLLER_CLIENT_ID'], $Settings['TEST_BAMI_BICEP_CLIENT_ID'])) {
            throw [System.InvalidOperationException]::new('Candidate execution requires a dedicated repository client ID, never the controller or shared Bicep identity.')
        }
    }
    $principalId = [guid]::Empty
    $unknownPrincipal = Test-AvmTerraformPlanUnknownField -Change $changes[$identityAddress]['change'] -Path 'output.properties.principalId'
    if (($null -eq $principal -and -not $unknownPrincipal) -or
        ($null -ne $principal -and ($principal -isnot [string] -or
            -not [guid]::TryParseExact($principal, 'D', [ref] $principalId) -or $principalId -eq [guid]::Empty -or
            $principalId -eq $controllerPrincipal))) {
        throw [System.InvalidOperationException]::new('Candidate group membership must use the dedicated repository principal, never the controller.')
    }
    foreach ($address in $membershipNames.Keys) {
        $groupName = $membershipNames[$address]
        $dataAddress = $address.Replace('azuread_group_member.', 'data.azuread_group.')
        $evidence = @($dataResources | Where-Object { $_['address'] -ceq $dataAddress })
        if ($evidence.Count -ne 1 -or $evidence[0]['mode'] -cne 'data' -or
            $evidence[0]['type'] -cne 'azuread_group' -or $evidence[0]['values'] -isnot [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new("Candidate membership requires exactly one target-tenant lookup for configured group '$groupName'.")
        }
        $values = $evidence[0]['values']
        $groupId = [guid]::Empty
        if ($values['object_id'] -isnot [string] -or -not [guid]::TryParseExact($values['object_id'], 'D', [ref] $groupId) -or
            $groupId -eq [guid]::Empty -or $values['display_name'] -cne $groupName -or
            $values['security_enabled'] -isnot [bool] -or $values['security_enabled'] -ne $true) {
            throw [System.InvalidOperationException]::new('Candidate group evidence must identify the configured security group in the selected tenant.')
        }
        $membership = @($managed | Where-Object { $_['address'] -ceq $address })[0]['values']
        $member = $membership['member_object_id']
        if ($membership['group_object_id'] -isnot [string] -or $membership['group_object_id'] -ine $groupId.ToString() -or
            ($null -ne $principal -and ($member -isnot [string] -or $member -ine $principal)) -or
            ($null -eq $principal -and ($null -ne $member -or
                -not (Test-AvmTerraformPlanUnknownField -Change $changes[$address]['change'] -Path 'member_object_id')))) {
            throw [System.InvalidOperationException]::new('Candidate membership must bind only the resolved configured group and dedicated repository principal.')
        }
    }
    foreach ($environment in @('pr-check', 'integration-test', 'examples-test', 'avm-validation')) {
        $address = if ($environment -ceq 'avm-validation') { $validationCredentialAddress } else {
            $ModuleAddress + '.azapi_resource.identity_federated_credentials["' + $environment + '"]'
        }
        $credential = @($managed | Where-Object { $_['address'] -ceq $address })[0]['values']
        if ($credential['body'] -isnot [System.Collections.IDictionary] -or
            $credential['body']['properties'] -isnot [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new('Candidate federation must have complete credential properties.')
        }
        $properties = $credential['body']['properties']
        $audiences = @($properties['audiences'])
        $subject = if ($environment -ceq 'avm-validation') {
            "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositorySyncRepositoryId}:environment:avm-validation"
        }
        else {
            "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositoryId}:environment:${environment}:job_workflow_ref:$JobWorkflowRef"
        }
        if ($credential['type'] -cne 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview' -or
            $credential['name'] -cne "$name-$environment" -or
            ($null -ne $credential['parent_id'] -and $credential['parent_id'] -cne $identityId) -or
            ($null -eq $credential['parent_id'] -and -not (Test-AvmTerraformPlanUnknownField -Change $changes[$address]['change'] -Path 'parent_id')) -or
            $properties['issuer'] -cne 'https://token.actions.githubusercontent.com' -or
            $audiences.Count -ne 1 -or $audiences[0] -cne 'api://AzureADTokenExchange' -or $properties['subject'] -cne $subject) {
            throw [System.InvalidOperationException]::new('Candidate federation, including validation federation, must retain the exact repository, environment, workflow, and identity binding.')
        }
    }
    $ownerDeletions = 0
    foreach ($change in $changes.Values) {
        $actions = @($change['change']['actions'])
        if ($change['address'] -cin $allowed -and $change['type'] -cne 'azuread_group_member') { continue }
        if ($change['address'] -cin $allowed -and $actions -notcontains 'delete' -and
            $null -eq $change['change']['before']) { continue }
        if ($change['mode'] -ceq 'data' -and $actions.Count -eq 1 -and $actions[0] -cin @('no-op', 'read')) { continue }
        $before = $change['change']['before']
        if ($change['mode'] -cne 'managed' -or $before -isnot [System.Collections.IDictionary] -or $null -eq $principal) {
            throw [System.InvalidOperationException]::new('Candidate plans must not delete or replace resources outside verified permission migration or revocation.')
        }
        $membershipAddress = $change['address'] -ceq "$ModuleAddress.azuread_group_member.example" -or
            $change['address'] -cmatch ('^' + [regex]::Escape($ModuleAddress) + '\.azuread_group_member\.test_permissions\["(?:[^"\\]|\\.)+"\]$')
        if ($change['type'] -ceq 'azuread_group_member' -and $membershipAddress) {
            $previousGroupId = [guid]::Empty
            $removed = ($actions -join ',') -ceq 'delete' -and $null -eq $change['change']['after']
            $retained = $change['address'] -cin $allowed -and
                ($actions -join ',') -cin @('no-op', 'update', 'delete,create', 'create,delete')
            if (($removed -or $retained) -and $before['member_object_id'] -is [string] -and
                $before['member_object_id'] -ieq $principal -and $before['group_object_id'] -is [string] -and
                [guid]::TryParseExact($before['group_object_id'], 'D', [ref] $previousGroupId) -and $previousGroupId -ne [guid]::Empty) {
                continue
            }
        }
        $ownerAddresses = @("$ModuleAddress.azapi_resource.identity_role_assignment", "$ModuleAddress.azapi_resource.identity_role_assignment[0]")
        if (($actions -join ',') -ceq 'delete' -and $null -eq $change['change']['after'] -and
            $change['address'] -cin $ownerAddresses -and $change['type'] -ceq 'azapi_resource' -and
            $before['body'] -is [System.Collections.IDictionary] -and $before['body']['properties'] -is [System.Collections.IDictionary]) {
            $assignmentName = Get-AvmBamiOwnerAssignmentName -Repository $Repository -Settings $Settings
            $scope = "/providers/Microsoft.Management/managementGroups/$($Settings['TEST_BAMI_MANAGEMENT_GROUP_ID'])"
            $properties = $before['body']['properties']
            if ($before['type'] -ceq 'Microsoft.Authorization/roleAssignments@2022-04-01' -and
                $before['parent_id'] -ceq $scope -and $before['name'] -ceq $assignmentName -and
                $before['id'] -ieq "$scope/providers/Microsoft.Authorization/roleAssignments/$assignmentName" -and
                $properties['roleDefinitionId'] -ceq '/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635' -and
                $properties['principalType'] -ceq 'ServicePrincipal' -and $properties['principalId'] -ieq $principal -and
                (-not $change.Contains('previous_address') -or $change['previous_address'] -ceq $ownerAddresses[0])) {
                $ownerDeletions++
                if ($ownerDeletions -eq 1) { continue }
            }
        }
        throw [System.InvalidOperationException]::new('Candidate change is not the exact obsolete Owner assignment or an individual membership edge for this repository principal.')
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

function Resolve-AvmRepositorySyncContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $RepoId,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $RepositorySyncRepositoryId,
        [bool] $PlanOnly = $false
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($RepoId -cnotmatch '^avm-(res|ptn|utl)-[a-z0-9]+(?:-[a-z0-9]+)*$' -or
        $Repository -cnotmatch ('^Azure/terraform-(azurerm|azure|azapi)-' + [regex]::Escape($RepoId) + '$')) {
        throw [System.ArgumentException]::new('Repository sync requires the selected canonical Azure AVM repository.')
    }
    Assert-AvmBamiRepositorySyncRunContext -PlanOnly $PlanOnly
    $toolsContext = Resolve-AvmRepositorySyncFederationContext -RepositoryId $RepositorySyncRepositoryId
    $repo = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository"
    if ($repo.full_name -cne $Repository -or $repo.fork -or $repo.id -le 0 -or
        [string]$repo.owner.id -cne $toolsContext.OrganizationId -or $repo.owner.login -cne 'Azure') {
        throw [System.InvalidOperationException]::new('GitHub returned an unexpected repository identity.')
    }
    return [pscustomobject]@{
        Repository = $repo
        RepositoryId = $toolsContext.RepositoryId
        OrganizationId = $toolsContext.OrganizationId
    }
}

function ConvertTo-AvmRepositoryTerraformSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Settings)

    $settings = Get-AvmBamiSettings -Values $Settings
    return @{
        tenant_id = $settings['TEST_BAMI_TENANT_ID']
        controller_client_id = $settings['TEST_BAMI_CONTROLLER_CLIENT_ID']
        bicep_client_id = $settings['TEST_BAMI_BICEP_CLIENT_ID']
        admin_subscription_id = $settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID']
        persistent_subscription_id = $settings['TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID']
        management_group_id = $settings['TEST_BAMI_MANAGEMENT_GROUP_ID']
        identity_resource_group_name = $settings['TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME']
        test_subscription_ids = ConvertFrom-AvmTestTenantJson -Json $settings['TEST_BAMI_SUBSCRIPTION_IDS']
    }
}

function Assert-AvmRetiredRepositoryIdentityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Changes,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [string] $Repository
    )

    $identityAddress = 'module.azure[0].azapi_resource.identity'
    $identities = @($Changes | Where-Object { $_['address'] -ceq $identityAddress })
    if ($identities.Count -ne 1) {
        throw [System.InvalidOperationException]::new('Partial retired-tenant state requires operator inventory; no objects may be silently forgotten.')
    }
    $identity = $identities[0]['change']['before']
    $tenant = [guid]::Empty
    $principal = [guid]::Empty
    if ($identity -isnot [System.Collections.IDictionary] -or
        $identity['output'] -isnot [System.Collections.IDictionary] -or
        $identity['output']['properties'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Retired state requires the original identity ownership evidence.')
    }
    $properties = $identity['output']['properties']
    $parentPattern = '^/subscriptions/([0-9a-fA-F-]{36})/resourceGroups/[^/]+$'
    if (-not [guid]::TryParseExact([string]$properties['tenantId'], 'D', [ref]$tenant) -or
        $tenant -eq [guid]::Empty -or $tenant.ToString() -ieq $Settings['TEST_BAMI_TENANT_ID'] -or
        -not [guid]::TryParseExact([string]$properties['principalId'], 'D', [ref]$principal) -or
        $principal -eq [guid]::Empty -or
        $identity['parent_id'] -cnotmatch $parentPattern -or
        $identity['parent_id'].StartsWith("/subscriptions/$($Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'])/", [StringComparison]::OrdinalIgnoreCase) -or
        $identity['type'] -cne 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' -or
        $identity['name'] -cne $Repository.Replace('/', '-').Replace('windows', 'w5s') -or
        $identity['id'] -ine "$($identity['parent_id'])/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($identity['name'])") {
        throw [System.InvalidOperationException]::new('Only the original repository identity in a different, retired tenant may be forgotten; live BAMI ownership must be transferred.')
    }
    foreach ($change in $Changes) {
        $before = $change['change']['before']
        if ($change['mode'] -cne 'managed' -or (@($change['change']['actions']) -join ',') -cne 'forget' -or
            $null -ne $change['change']['after'] -or $before -isnot [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new('Retired-tenant entries may only be forgotten without refresh or destruction.')
        }
        if ($change['address'] -ceq $identityAddress -and $change['type'] -ceq 'azapi_resource') { continue }
        if ($change['address'] -ceq 'module.azure[0].azuread_group_member.example' -and
            $change['type'] -ceq 'azuread_group_member' -and $before['member_object_id'] -ieq $principal.ToString()) {
            $group = [guid]::Empty
            if ([guid]::TryParseExact([string]$before['group_object_id'], 'D', [ref]$group) -and $group -ne [guid]::Empty) { continue }
        }
        if ($change['type'] -ceq 'azapi_resource' -and
            $change['address'] -cmatch '^module\.azure\[0\]\.azapi_resource\.(identity_federated_credentials\["(pr-check|integration-test|examples-test|avm-validation)"\]|validation_federated_credential)$' -and
            $before['type'] -ceq 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview' -and
            $before['parent_id'] -ieq $identity['id']) { continue }
        if ($change['address'] -cin @('module.azure[0].azapi_resource.identity_role_assignment', 'module.azure[0].azapi_resource.identity_role_assignment[0]') -and
            $change['type'] -ceq 'azapi_resource' -and
            $before['type'] -ceq 'Microsoft.Authorization/roleAssignments@2022-04-01' -and
            $before['body'] -is [System.Collections.IDictionary] -and $before['body']['properties'] -is [System.Collections.IDictionary] -and
            $before['body']['properties']['principalId'] -ieq $principal.ToString() -and
            $before['body']['properties']['roleDefinitionId'] -ceq '/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635' -and
            $before['body']['properties']['principalType'] -ceq 'ServicePrincipal') { continue }
        throw [System.InvalidOperationException]::new('Retired state contains an unexpected address or ownership binding; operator review is required.')
    }
}

function Assert-AvmRepositorySyncPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan,
        [AllowNull()] [System.Collections.IDictionary] $Settings,
        [AllowNull()] [object] $Repository,
        [string] $RepositorySyncRepositoryId,
        [string[]] $EntraGroupNames = @(),
        [string] $JobWorkflowRef = 'Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main',
        [string[]] $ResourceTypesThatCannotBeDestroyed = @('github_repository')
    )

    if ($Plan['errored'] -eq $true -or $Plan['resource_changes'] -isnot [System.Collections.IList] -or
        $Plan['planned_values'] -isnot [System.Collections.IDictionary] -or
        $Plan['planned_values']['root_module'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Repository Terraform plan is incomplete or errored.')
    }
    $resources = @(Get-AvmTerraformPlannedResource -Module $Plan['planned_values']['root_module'])
    $addresses = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $retired = [System.Collections.Generic.List[object]]::new()
    foreach ($change in $Plan['resource_changes']) {
        if ($change -isnot [System.Collections.IDictionary] -or $change['address'] -isnot [string] -or
            $change['change'] -isnot [System.Collections.IDictionary] -or -not $addresses.Add($change['address'])) {
            throw [System.InvalidOperationException]::new('Repository plan contains missing or ambiguous resource changes.')
        }
        if ($change['change']['actions'] -contains 'delete' -and $change['type'] -in $ResourceTypesThatCannotBeDestroyed) {
            throw [System.InvalidOperationException]::new("Repository plan would destroy protected resource '$($change['address'])'.")
        }
        if ($change['address'].StartsWith('module.azure[0].', [StringComparison]::Ordinal)) {
            $provider = if ($change['type'] -ceq 'azapi_resource') { 'registry.terraform.io/azure/azapi' } else { 'registry.terraform.io/hashicorp/azuread' }
            if ($change['provider_name'] -cne $provider) {
                throw [System.InvalidOperationException]::new('Retired state has an unexpected provider binding.')
            }
            $retired.Add($change)
            continue
        }
        if ($change['address'].StartsWith('module.github.', [StringComparison]::Ordinal) -and
            $change['type'] -cmatch '^github_' -and $change['provider_name'] -ceq 'registry.terraform.io/integrations/github') { continue }
        if ($null -ne $Settings -and $change['address'].StartsWith('module.bami[0].', [StringComparison]::Ordinal) -and
            (($change['type'] -cmatch '^azapi_' -and $change['provider_name'] -ceq 'registry.terraform.io/azure/azapi') -or
                ($change['type'] -cmatch '^azuread_' -and $change['provider_name'] -ceq 'registry.terraform.io/hashicorp/azuread'))) { continue }
        throw [System.InvalidOperationException]::new('Repository plan contains an unexpected resource address or provider binding.')
    }
    foreach ($resource in $resources) {
        if ($resource['mode'] -ceq 'data') { continue }
        if (-not $addresses.Contains($resource['address'])) {
            throw [System.InvalidOperationException]::new('Repository plan omits a managed resource change.')
        }
    }
    if ($null -eq $Settings) {
        if ($retired.Count -gt 0) {
            throw [System.InvalidOperationException]::new('Repository creation cannot retire identity state.')
        }
        return
    }
    $githubChanges = @($Plan['resource_changes'] | Where-Object { $_['address'] -ceq 'module.github.github_repository.this' })
    if ($githubChanges.Count -ne 1 -or $githubChanges[0]['mode'] -cne 'managed' -or $githubChanges[0]['type'] -cne 'github_repository') {
        throw [System.InvalidOperationException]::new('Repository plan must include exactly the verified GitHub repository.')
    }
    $expectedRepository = @{
        name = $Repository.full_name.Split('/')[1]
        full_name = $Repository.full_name
        repo_id = [string]$Repository.id
    }
    foreach ($side in @('before', 'after')) {
        $values = $githubChanges[0]['change'][$side]
        if ($side -ceq 'before' -and $null -eq $values) { continue }
        if ($values -isnot [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new('Repository plan has incomplete GitHub ownership values.')
        }
        foreach ($field in $expectedRepository.Keys) {
            if ($side -ceq 'before' -and $field -cne 'repo_id') { continue }
            $unknown = $githubChanges[0]['change']['after_unknown']
            if ($side -ceq 'after' -and $field -cne 'name' -and
                $unknown -is [System.Collections.IDictionary] -and $unknown[$field] -eq $true) { continue }
            if ([string]$values[$field] -cne $expectedRepository[$field]) {
                throw [System.InvalidOperationException]::new('Repository plan would manage a different GitHub repository; inspect backend ownership.')
            }
        }
    }
    if ($retired.Count -gt 0) {
        Assert-AvmRetiredRepositoryIdentityPlan -Changes $retired.ToArray() -Settings $Settings -Repository $Repository.full_name
    }
    $identityPlan = @{
        errored = $false
        resource_changes = @($Plan['resource_changes'] | Where-Object { $_['address'].StartsWith('module.bami[0].', [StringComparison]::Ordinal) })
        planned_values = @{ root_module = @{ resources = @($resources | Where-Object { $_['address'].StartsWith('module.bami[0].', [StringComparison]::Ordinal) }) } }
        prior_state = $Plan['prior_state']
    }
    Assert-AvmBamiIdentityPlan -Plan $identityPlan -Settings $Settings -Repository $Repository.full_name `
        -RepositoryId ([string]$Repository.id) -RepositoryOwnerId ([string]$Repository.owner.id) `
        -RepositorySyncRepositoryId $RepositorySyncRepositoryId -JobWorkflowRef $JobWorkflowRef `
        -EntraGroupNames $EntraGroupNames -ModuleAddress 'module.bami[0]'
}
