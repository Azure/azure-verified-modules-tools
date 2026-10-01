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
        TEST_BAMI_ENTRA_READERS_GROUP_ID = '10000000-0000-4000-8000-000000000008'
        TEST_BAMI_TEST_IDENTITY_OWNERS_GROUP_ID = '10000000-0000-4000-8000-000000000009'
        TEST_BAMI_FABRIC_ADMINS_GROUP_ID = '10000000-0000-4000-8000-000000000010'
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
        [switch] $FabricAdminApis,
        [switch] $OwnerMigration,
        [switch] $FabricRevocation,
        [string] $RepositoryOwnerId = '6844498',
        [string] $RepositorySyncRepositoryId = '1239632211',
        [string] $JobWorkflowRef = 'Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main'
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
        @{
            address = 'module.azure.azuread_group_member.test_identity_owners[0]'
            mode = 'managed'
            type = 'azuread_group_member'
            values = @{
                group_object_id = $settings.TEST_BAMI_TEST_IDENTITY_OWNERS_GROUP_ID
                member_object_id = if ($KnownClient) { $principalId } else { $null }
            }
        }
        @{
            address = 'module.azure.azuread_group_member.example'; mode = 'managed'; type = 'azuread_group_member'
            values = @{
                group_object_id = $settings.TEST_BAMI_ENTRA_READERS_GROUP_ID
                member_object_id = if ($KnownClient) { $principalId } else { $null }
            }
        }
    )
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
    if ($FabricAdminApis) {
        $resources += @{
            address = 'module.azure.azuread_group_member.fabric_admins[0]'; mode = 'managed'; type = 'azuread_group_member'
            values = @{
                group_object_id = $settings.TEST_BAMI_FABRIC_ADMINS_GROUP_ID
                member_object_id = if ($KnownClient) { $principalId } else { $null }
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
                change = @{ actions = $actions; after = $_.values.Clone(); after_unknown = $unknown; after_sensitive = @{} }
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
    if ($FabricRevocation) {
        $changes += @{
            address = 'module.azure.azuread_group_member.fabric_admins[0]'; mode = 'managed'; type = 'azuread_group_member'
            change = @{
                actions = @('delete'); after = $null
                before = @{ group_object_id = $settings.TEST_BAMI_FABRIC_ADMINS_GROUP_ID; member_object_id = $principalId }
            }
        }
    }
    $resources += @{
        address = 'module.azure.data.azapi_client_config.current'; mode = 'data'; type = 'azapi_client_config'
        values = @{ tenant_id = $settings.TEST_BAMI_TENANT_ID; subscription_id = $settings.TEST_BAMI_ADMIN_SUBSCRIPTION_ID }
    }, @{
        address = 'module.azure.data.azuread_client_config.bami[0]'; mode = 'data'; type = 'azuread_client_config'
        values = @{ tenant_id = $settings.TEST_BAMI_TENANT_ID; client_id = $settings.TEST_BAMI_CONTROLLER_CLIENT_ID; object_id = '10000000-0000-4000-8000-000000000011' }
    }
    foreach ($group in @(
        @{ Address = 'module.azure.data.azuread_group.entra_readers'; Id = $settings.TEST_BAMI_ENTRA_READERS_GROUP_ID; Name = 'avm-test-entra-readers' }
        @{ Address = 'module.azure.data.azuread_group.test_permissions["test_identity_owners"]'; Id = $settings.TEST_BAMI_TEST_IDENTITY_OWNERS_GROUP_ID; Name = 'avm-test-identity-owners' }
        @{ Address = 'module.azure.data.azuread_group.test_permissions["fabric_admins"]'; Id = $settings.TEST_BAMI_FABRIC_ADMINS_GROUP_ID; Name = 'avm-test-fabric-admins' }
    )) {
        $resources += @{
            address = $group.Address; mode = 'data'; type = 'azuread_group'
            values = @{ object_id = $group.Id; display_name = $group.Name; security_enabled = $true; mail_enabled = $false; types = @(); onpremises_sync_enabled = $null }
        }
    }
    return @{
        format_version = '1.2'
        errored = $false
        resource_changes = $changes
        planned_values = @{
            root_module = @{ child_modules = @(@{ address = 'module.azure'; resources = $resources }) }
            outputs = @{ test_identity = @{ value = $identity } }
        }
    }
}
