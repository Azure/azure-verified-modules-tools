function New-AvmTestBamiSettings {
    $subscriptions = foreach ($number in 1..28) {
        @{ name = "test-$number"; id = '00000000-0000-4000-8000-{0:000000000000}' -f $number }
    }
    return @{
        TEST_BAMI_TENANT_ID = '10000000-0000-4000-8000-000000000001'
        TEST_BAMI_CONTROLLER_CLIENT_ID = '10000000-0000-4000-8000-000000000002'
        TEST_BAMI_ADMIN_SUBSCRIPTION_ID = '10000000-0000-4000-8000-000000000003'
        TEST_BAMI_SUBSCRIPTION_IDS = $subscriptions
        TEST_BAMI_MANAGEMENT_GROUP_ID = 'mg-bami-test'
        TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME = 'rg-bami-test'
        TEST_BAMI_BICEP_CLIENT_ID = '10000000-0000-4000-8000-000000000004'
        TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID = '10000000-0000-4000-8000-000000000005'
    }
}

function New-AvmTestBamiIdentity {
    return @{
        tenant_id = '10000000-0000-4000-8000-000000000001'
        client_id = '10000000-0000-4000-8000-000000000006'
        identity_resource_id = '/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Azure-terraform-azurerm-avm-ptn-example-repo'
        repository_id = '1234'
        repository_owner_id = '6844498'
    }
}

function New-AvmTestBamiPlan {
    param(
        [switch] $KnownClient,
        [switch] $ValidationPending,
        [switch] $OwnerMigration,
        [switch] $LegacyMembershipMigration,
        [string] $RemovedGroup,
        [string[]] $GroupNames = @('avm-test-identity-owners', 'avm-test-entra-readers'),
        [string] $RepositoryOwnerId = '6844498',
        [string] $RepositorySyncRepositoryId = '1239632211',
        [string] $JobWorkflowRef = 'Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main',
        [string] $ModuleAddress = 'module.azure'
    )

    $condition = @'
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
 )
 OR
 (
  @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, 8e3af657-a8ff-443c-a75c-2fe8c4bcb635, f58310d9-a9f6-439a-9e8d-f62e7b41a168}
 )
)
AND
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
 )
 OR
 (
  @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, 8e3af657-a8ff-443c-a75c-2fe8c4bcb635, f58310d9-a9f6-439a-9e8d-f62e7b41a168}
 )
)
'@
    $identity = New-AvmTestBamiIdentity
    $settings = New-AvmTestBamiSettings
    $principalId = '10000000-0000-4000-8000-000000000007'
    if (-not $KnownClient) { $identity.Remove('client_id') }
    $resources = @(
        @{
            address = 'module.azure.azapi_resource.identity'
            mode = 'managed'
            type = 'azapi_resource'
            values = @{
                type = 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview'
                parent_id = '/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test'
                name = 'Azure-terraform-azurerm-avm-ptn-example-repo'
                id = if ($KnownClient) { $identity.identity_resource_id } else { $null }
                output = if ($KnownClient) {
                    @{ properties = @{ tenantId = $identity.tenant_id; clientId = $identity.client_id; principalId = $principalId } }
                } else { $null }
            }
        }

    )
    $groups = @{}
    $number = 8
    foreach ($groupName in $GroupNames) {
        $groups[$groupName] = '10000000-0000-4000-8000-{0:000000000000}' -f $number
        $key = ConvertTo-Json -InputObject $groupName -Compress
        $resources += @{
            address = "module.azure.azuread_group_member.test_permissions[$key]"
            mode = 'managed'; type = 'azuread_group_member'
            values = @{
                group_object_id = $groups[$groupName]
                member_object_id = if ($KnownClient) { $principalId } else { $null }
            }
        }
        $number++
    }
    foreach ($environment in @('pr-check', 'integration-test', 'examples-test', 'avm-validation')) {
        $resources += @{
            address = if ($environment -ceq 'avm-validation') { 'module.azure.azapi_resource.validation_federated_credential' } else {
                'module.azure.azapi_resource.identity_federated_credentials["' + $environment + '"]'
            }
            mode = 'managed'
            type = 'azapi_resource'
            values = @{
                type = 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview'
                name = "Azure-terraform-azurerm-avm-ptn-example-repo-$environment"
                parent_id = if ($KnownClient) { $identity.identity_resource_id } else { $null }
                body = @{
                    properties = @{
                        audiences = @('api://AzureADTokenExchange')
                        issuer = 'https://token.actions.githubusercontent.com'
                        subject = if ($environment -ceq 'avm-validation') {
                            "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositorySyncRepositoryId}:environment:avm-validation"
                        } else {
                            "repository_owner_id:${RepositoryOwnerId}:repository_id:1234:environment:${environment}:job_workflow_ref:$JobWorkflowRef"
                        }
                    }
                }
            }
        }
    }
    $changes = @($resources | ForEach-Object {
            $actions = @(if ($KnownClient -and (-not $ValidationPending -or
                    $_.address -cne 'module.azure.azapi_resource.validation_federated_credential')) {
                'no-op'
            }
            else {
                'create'
            })
            $unknown = if ($KnownClient) { @{} } elseif ($_.type -ceq 'azuread_group_member') {
                @{ member_object_id = $true }
            } elseif ($_.address -ceq 'module.azure.azapi_resource.identity') {
                @{ id = $true; output = $true }
            } else {
                @{ parent_id = $true }
            }
            @{ address = $_.address; mode = $_.mode; type = $_.type
                change = @{
                    actions = $actions; after = $_.values.Clone(); after_unknown = $unknown; after_sensitive = @{}
                    before = if ($KnownClient -and $actions[0] -ceq 'no-op') { $_.values.Clone() } else { $null }
                }
            }
        })
    if ($OwnerMigration) {
        $assignmentName = Get-AvmBamiOwnerAssignmentName -Repository 'Azure/terraform-azurerm-avm-ptn-example-repo' -Settings $settings
        $scope = "/providers/Microsoft.Management/managementGroups/$($settings.TEST_BAMI_MANAGEMENT_GROUP_ID)"
        $changes += @{
            address = 'module.azure.azapi_resource.identity_role_assignment[0]'
            previous_address = 'module.azure.azapi_resource.identity_role_assignment'
            mode = 'managed'; type = 'azapi_resource'
            change = @{
                actions = @('delete'); after = $null
                before = @{
                    type = 'Microsoft.Authorization/roleAssignments@2022-04-01'
                    name = $assignmentName; parent_id = $scope
                    id = "$scope/providers/Microsoft.Authorization/roleAssignments/$assignmentName"
                    body = @{ properties = @{
                        roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
                        principalType = 'ServicePrincipal'; principalId = $principalId
                        conditionVersion = '2.0'; condition = $condition
                    } }
                }
            }
        }
    }
    if ($RemovedGroup -or $LegacyMembershipMigration) {
        $key = ConvertTo-Json -InputObject $RemovedGroup -Compress
        $changes += @{
            address = if ($LegacyMembershipMigration) { 'module.azure.azuread_group_member.example' } else {
                "module.azure.azuread_group_member.test_permissions[$key]"
            }
            mode = 'managed'; type = 'azuread_group_member'
            change = @{
                actions = @('delete'); after = $null
                before = @{ group_object_id = '10000000-0000-4000-8000-000000000099'; member_object_id = $principalId }
            }
        }
    }
    $resources += @{
        address = 'module.azure.data.azapi_client_config.current'; mode = 'data'; type = 'azapi_client_config'
        values = @{ tenant_id = $settings.TEST_BAMI_TENANT_ID; subscription_id = $settings.TEST_BAMI_ADMIN_SUBSCRIPTION_ID }
    }, @{
        address = 'module.azure.data.azuread_client_config.current'; mode = 'data'; type = 'azuread_client_config'
        values = @{ tenant_id = $settings.TEST_BAMI_TENANT_ID; client_id = $settings.TEST_BAMI_CONTROLLER_CLIENT_ID; object_id = '10000000-0000-4000-8000-000000000011' }
    }
    foreach ($groupName in $GroupNames) {
        $key = ConvertTo-Json -InputObject $groupName -Compress
        $resources += @{
            address = "module.azure.data.azuread_group.test_permissions[$key]"; mode = 'data'; type = 'azuread_group'
            values = @{ object_id = $groups[$groupName]; display_name = $groupName; security_enabled = $true; types = @() }
        }
    }
    foreach ($item in @($resources) + @($changes)) {
        $item.address = $item.address.Replace('module.azure.', "$ModuleAddress.")
        if ($item.ContainsKey('previous_address')) {
            $item.previous_address = $item.previous_address.Replace('module.azure.', "$ModuleAddress.")
        }
        $item.provider_name = $item.type -like 'azapi_*' ? 'registry.terraform.io/azure/azapi' : 'registry.terraform.io/hashicorp/azuread'
    }
    return @{
        format_version = '1.2'
        errored = $false
        resource_changes = $changes
        planned_values = @{
            root_module = @{ child_modules = @(@{
                address = $ModuleAddress
                resources = @($resources | Where-Object { $_['mode'] -ceq 'managed' })
            }) }
            outputs = @{ test_identity = @{ value = $identity } }
        }
        prior_state = @{
            values = @{ root_module = @{ child_modules = @(@{
                address = $ModuleAddress
                resources = @($resources | Where-Object { $_['mode'] -ceq 'data' })
            }) } }
        }
    }
}

function New-AvmTestRepositorySyncPlan {
    param(
        [switch] $KnownClient,
        [switch] $OwnerMigration,
        [switch] $LegacyMembershipMigration
    )

    $plan = New-AvmTestBamiPlan -ModuleAddress 'module.bami[0]' -KnownClient:$KnownClient `
        -OwnerMigration:$OwnerMigration -LegacyMembershipMigration:$LegacyMembershipMigration
    $github = @{
        address = 'module.github.github_repository.this'
        mode = 'managed'
        type = 'github_repository'
        provider_name = 'registry.terraform.io/integrations/github'
        values = @{
            id = 'terraform-azurerm-avm-ptn-example-repo'; repo_id = 1234
            name = 'terraform-azurerm-avm-ptn-example-repo'; full_name = 'Azure/terraform-azurerm-avm-ptn-example-repo'
        }
    }
    $plan.planned_values.root_module.child_modules += @{
        address = 'module.github'
        resources = @($github)
    }
    $plan.resource_changes += @{
        address = $github.address; mode = $github.mode; type = $github.type; provider_name = $github.provider_name
        change = @{ actions = @('no-op'); before = $github.values.Clone(); after = $github.values; after_unknown = @{} }
    }
    return $plan
}

function New-AvmTestRetiredIdentityChanges {
    $plan = New-AvmTestBamiPlan -KnownClient -OwnerMigration -LegacyMembershipMigration -GroupNames @() -ModuleAddress 'module.azure[0]'
    $plan = ($plan | ConvertTo-Json -Depth 100).Replace('10000000-', '20000000-').Replace('rg-bami-test', 'rg-retired-test') |
        ConvertFrom-Json -AsHashtable -Depth 100
    foreach ($change in $plan.resource_changes) {
        $change.change.actions = @('forget')
        $change.change.after = $null
        $change.change.after_unknown = @{}
        $change.Remove('previous_address')
    }
    return $plan.resource_changes
}
