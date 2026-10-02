#Requires -Version 7.4

. (Join-Path $PSScriptRoot '..' '..' '..' 'shared' 'TestTenant.ps1')
. (Join-Path $PSScriptRoot 'RetryHelpers.ps1')
. (Join-Path $PSScriptRoot 'TerraformOperations.ps1')

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
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $EntraGroupNames
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
    $identityAddress = 'module.azure.azapi_resource.identity'
    $validationCredentialAddress = 'module.azure.azapi_resource.validation_federated_credential'
    $membershipNames = @{}
    foreach ($groupName in $EntraGroupNames) {
        $key = ConvertTo-Json -InputObject $groupName -Compress
        $membershipNames["module.azure.azuread_group_member.test_permissions[$key]"] = $groupName
    }
    $allowed = @(
        $identityAddress,
        'module.azure.azapi_resource.identity_federated_credentials["pr-check"]',
        'module.azure.azapi_resource.identity_federated_credentials["integration-test"]',
        'module.azure.azapi_resource.identity_federated_credentials["examples-test"]',
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
        $identity['type'] -cne 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview') {
        throw [System.InvalidOperationException]::new('Candidate identity is not scoped to the expected repository and BAMI resource group.')
    }
    $azureContexts = @($resources | Where-Object { $_['address'] -ceq 'module.azure.data.azapi_client_config.current' })
    $graphContexts = @($resources | Where-Object { $_['address'] -ceq 'module.azure.data.azuread_client_config.current' })
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
        $evidence = @($resources | Where-Object { $_['address'] -ceq $dataAddress })
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
            'module.azure.azapi_resource.identity_federated_credentials["' + $environment + '"]'
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
        $membershipAddress = $change['address'] -ceq 'module.azure.azuread_group_member.example' -or
            $change['address'] -cmatch '^module\.azure\.azuread_group_member\.test_permissions\["(?:[^"\\]|\\.)+"\]$'
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
        $ownerAddresses = @('module.azure.azapi_resource.identity_role_assignment', 'module.azure.azapi_resource.identity_role_assignment[0]')
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
    foreach ($resource in @($resources) + @($Plan['resource_changes'])) {
        if ($resource['type'] -ceq 'azuread_group_member' -and $resource['mode'] -ceq 'managed') {
            $fields[$resource['address']] = [ordered]@{ group_object_id = 'group_object_id'; member_object_id = 'member_object_id' }
        }
    }
    foreach ($address in @('module.azure.azapi_resource.identity_role_assignment', 'module.azure.azapi_resource.identity_role_assignment[0]')) {
        if (@($Plan['resource_changes'] | Where-Object { $_['address'] -ceq $address }).Count -gt 0) {
            $fields[$address] = [ordered]@{
                type = 'type'
                name = 'name'
                id = 'id'
                parent_id = 'parent_id'
                roleDefinitionId = 'body.properties.roleDefinitionId'
                principalId = 'body.properties.principalId'
                principalType = 'body.properties.principalType'
                conditionVersion = 'body.properties.conditionVersion'
                condition = 'body.properties.condition'
            }
        }
    }
    $summaryResources = @(
        foreach ($address in $fields.Keys) {
            $matchesForAddress = @($resources | Where-Object { $_['address'] -ceq $address })
            $resource = if ($matchesForAddress.Count -eq 1) { $matchesForAddress[0] } else { $null }
            $changes = @($Plan['resource_changes'] | Where-Object { $_ -and $_['address'] -ceq $address })
            $change = if ($changes.Count -eq 1) { $changes[0]['change'] } else { @{} }
            $actions = @($change['actions'])
            $fieldChange = $change
            if ($actions.Count -eq 1 -and $actions[0] -ceq 'delete') {
                $resource = @{ values = $change['before']; sensitive_values = $change['before_sensitive'] }
                $fieldChange = @{ after_sensitive = $change['before_sensitive']; after_unknown = @{} }
            }
            $entry = [ordered]@{
                address = $address
                actions = if ($actions.Count -gt 0 -and @($actions | Where-Object {
                            $_ -isnot [string] -or $_ -cnotin @('no-op', 'create', 'update', 'delete')
                        }).Count -eq 0) { ,$actions } else { '[unavailable: missing or ambiguous actions]' }
            }
            foreach ($field in $fields[$address].Keys) {
                $entry[$field] = & $readField -Resource $resource -Change $fieldChange -Path $fields[$address][$field]
            }
            $entry
        }
    )
    $groups = @(
        foreach ($resource in $resources) {
            if ($resource['mode'] -ceq 'data' -and $resource['type'] -ceq 'azuread_group' -and
                $resource['address'].StartsWith('module.azure.data.azuread_group.test_permissions[')) {
                [ordered]@{
                    display_name = & $readField -Resource $resource -Change @{} -Path 'display_name'
                    object_id = & $readField -Resource $resource -Change @{} -Path 'object_id'
                }
            }
        }
    )
    $summary = [ordered]@{
        repository = $Repository.full_name
        repository_id = [string]$Repository.id
        repository_owner_id = [string]$Repository.owner.id
        expected_tenant_id = $TenantId
        groups = $groups
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
        [bool] $PlanOnly = $true,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $EntraGroupNames
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $settings = Get-AvmBamiSettings -Values $BamiValues
    $EntraGroupNames = ConvertTo-AvmEntraGroupNames -Names $EntraGroupNames
    $stateKey = Get-AvmBamiIdentityStateKey -TenantId $settings['TEST_BAMI_TENANT_ID'] -RepoId $RepoId
    $state = Resolve-RepositorySyncStateConfiguration -Backend $Backend
    if ($Repository -cnotmatch ('^Azure/terraform-(azurerm|azure|azapi)-' + [regex]::Escape($RepoId) + '$')) {
        throw [System.ArgumentException]::new('Candidate identities are limited to the selected Azure AVM repository.')
    }
    if ($env:GITHUB_REF -cne 'refs/heads/main') {
        throw [System.InvalidOperationException]::new('BAMI repository sync requires trusted Azure/azure-verified-modules-tools main in GitHub Actions.')
    }
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
            identity_resource_group_name = $settings['TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME']
            entra_group_names = $EntraGroupNames
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
            -RepositoryId ([string]$repo.id) -RepositoryOwnerId $toolsContext.OrganizationId `
            -RepositorySyncRepositoryId $toolsContext.RepositoryId -JobWorkflowRef $JobWorkflowRef -EntraGroupNames $EntraGroupNames
        Write-AvmBamiIdentityPlanSummary -Plan $plan -Repository $repo -TenantId $settings['TEST_BAMI_TENANT_ID']
        if ($PlanOnly -and @($plan['resource_changes'] | Where-Object {
                    $_ -and $_['mode'] -ceq 'managed' -and
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
