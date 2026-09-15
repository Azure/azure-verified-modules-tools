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
    param([switch] $KnownClient)

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
    $resources = @(
        @{
            address = 'module.azure.azapi_resource.identity'
            mode = 'managed'
            type = 'azapi_resource'
            values = @{
                parent_id = '/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test'
                name = 'Azure-terraform-azurerm-avm-ptn-example-repo'
            }
        }
        @{
            address = 'module.azure.azapi_resource.identity_role_assignment'
            mode = 'managed'
            type = 'azapi_resource'
            values = @{
                parent_id = '/providers/Microsoft.Management/managementGroups/mg-bami-test'
                body = @{
                    properties = @{
                        roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
                        conditionVersion = '2.0'
                        condition = $condition
                    }
                }
            }
        }
        @{ address = 'module.azure.azuread_group_member.example'; mode = 'managed'; type = 'azuread_group_member'; values = @{} }
    )
    foreach ($environment in @('pr-check', 'integration-test', 'examples-test')) {
        $resources += @{
            address = 'module.azure.azapi_resource.identity_federated_credentials["' + $environment + '"]'
            mode = 'managed'
            type = 'azapi_resource'
            values = @{}
        }
    }
    $identity = New-AvmTestBamiIdentity
    if (-not $KnownClient) { $identity.Remove('client_id') }
    return @{
        format_version = '1.2'
        errored = $false
        resource_changes = @($resources | ForEach-Object { @{ address = $_.address; change = @{ actions = @('create') } } })
        planned_values = @{
            root_module = @{ child_modules = @(@{ address = 'module.azure'; resources = $resources }) }
            outputs = @{ test_identity = @{ value = $identity } }
        }
    }
}
