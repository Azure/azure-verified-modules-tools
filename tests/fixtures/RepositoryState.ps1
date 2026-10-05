. (Join-Path $PSScriptRoot 'TestTenant.ps1')

function New-AvmTestRepositoryStatePair {
    $repository = 'Azure/terraform-azurerm-avm-ptn-example-repo'
    $resourceId = '/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/' + $repository.Replace('/', '-')
    $identity = @{
        identity_resource_id = $resourceId
        tenant_id = '10000000-0000-4000-8000-000000000001'
        client_id = '10000000-0000-4000-8000-000000000006'
        principal_id = '10000000-0000-4000-8000-000000000007'
        repository_id = '1234'
        repository_owner_id = '6844498'
    }

    $source = @{
        version = 4; terraform_version = '1.16.4'; serial = 5
        lineage = '10000000-0000-4000-8000-000000000011'
        outputs = @{
            test_identity = @{
                value = @{
                    identity_resource_id = $identity.identity_resource_id; tenant_id = $identity.tenant_id
                    client_id = $identity.client_id; repository_id = $identity.repository_id; repository_owner_id = $identity.repository_owner_id
                }
                type = @('object', @{
                    identity_resource_id = 'string'; tenant_id = 'string'; client_id = 'string'
                    repository_id = 'string'; repository_owner_id = 'string'
                })
            }
            preserved_private_output = @{ value = 'synthetic-sensitive-value'; type = 'string'; sensitive = $true }
        }
        resources = @(
            @{
                module = 'module.azure'; mode = 'managed'; type = 'azapi_resource'; name = 'identity'
                provider = 'provider["registry.terraform.io/azure/azapi"]'
                instances = @(@{
                    schema_version = 2
                    attributes = @{
                        id = $resourceId
                        output = @{
                            value = @{ properties = @{
                                clientId = $identity.client_id; principalId = $identity.principal_id; tenantId = $identity.tenant_id
                            } }
                            type = @('object', @{ properties = @('object', @{ clientId = 'string'; principalId = 'string'; tenantId = 'string' }) })
                        }
                    }
                    private = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('synthetic opaque provider-private data'))
                    sensitive_attributes = @(, @(@{ type = 'get_attr'; value = 'output' }))
                    dependencies = @('module.azure.data.azapi_client_config.current')
                })
            }
            @{
                module = 'module.azure'; mode = 'data'; type = 'azapi_client_config'; name = 'current'
                provider = 'provider["registry.terraform.io/azure/azapi"]'
                instances = @(@{ schema_version = 0; attributes = @{ tenant_id = $identity.tenant_id }; sensitive_attributes = @() })
            }
            @{
                module = 'module.azure'; mode = 'managed'; type = 'azuread_group_member'; name = 'example'
                provider = 'provider["registry.terraform.io/hashicorp/azuread"]'
                instances = @(@{
                    schema_version = 0
                    attributes = @{
                        id = "10000000-0000-4000-8000-000000000008/member/$($identity.principal_id)"
                        group_object_id = '10000000-0000-4000-8000-000000000008'
                        member_object_id = $identity.principal_id
                    }
                    sensitive_attributes = @()
                    dependencies = @('module.azure.azapi_resource.identity')
                })
            }
            @{
                module = 'module.azure'; mode = 'managed'; type = 'azapi_resource'; name = 'identity_role_assignment'
                provider = 'provider["registry.terraform.io/azure/azapi"]'
                instances = @(@{
                    index_key = 0; schema_version = 2
                    attributes = @{
                        id = '/providers/Microsoft.Management/managementGroups/synthetic/providers/Microsoft.Authorization/roleAssignments/10000000-0000-4000-8000-000000000009'
                        body = @{ properties = @{ principalId = $identity.principal_id; roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635' } }
                    }
                    sensitive_attributes = @()
                    dependencies = @('module.azure.azapi_resource.identity')
                })
            }
        )
        check_results = $null
    }
    $destination = @{
        version = 4; terraform_version = '1.16.4'; serial = 9
        lineage = '10000000-0000-4000-8000-000000000012'
        outputs = @{ repository = @{ value = $repository; type = 'string' } }
        resources = @(
            @{
                module = 'module.github'; mode = 'managed'; type = 'github_repository'; name = 'this'
                provider = 'provider["registry.terraform.io/integrations/github"]'
                instances = @(@{
                    schema_version = 0
                    attributes = @{ id = $repository.Split('/')[1]; full_name = $repository; repo_id = 1234 }
                    sensitive_attributes = @()
                })
            }
            @{
                module = 'module.azure[0]'; mode = 'managed'; type = 'azapi_resource'; name = 'identity'
                provider = 'provider["registry.terraform.io/azure/azapi"]'
                instances = @(@{
                    schema_version = 2
                    attributes = @{ id = $resourceId.Replace('10000000-0000-4000-8000-000000000003', '20000000-0000-4000-8000-000000000003') }
                    sensitive_attributes = @()
                })
            }
        )
        check_results = $null
    }
    return @{ Repository = $repository; Identity = $identity; Source = $source; Destination = $destination }
}

function New-AvmTestMigrationStatePair {
    $pair = New-AvmTestRepositoryStatePair
    foreach ($name in @('pr-check', 'integration-test', 'examples-test', 'avm-validation')) {
        $validation = $name -ceq 'avm-validation'
        $repositoryId = $validation ? '5678' : $pair.Identity.repository_id
        $subject = "repository_owner_id:$($pair.Identity.repository_owner_id):repository_id:${repositoryId}:environment:$name"
        if (-not $validation) {
            $subject += ':job_workflow_ref:Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main'
        }
        $instance = @{
            schema_version = 2
            attributes = @{
                id = "$($pair.Identity.identity_resource_id)/federatedIdentityCredentials/$($pair.Repository.Replace('/', '-'))-$name"
                body = @{
                    value = @{ properties = @{
                        issuer = 'https://token.actions.githubusercontent.com'
                        audiences = @('api://AzureADTokenExchange')
                        subject = $subject
                    } }
                    type = @('object', @{ properties = @('object', @{
                        issuer = 'string'; audiences = @('tuple', @('string')); subject = 'string'
                    }) })
                }
            }
            sensitive_attributes = @()
            dependencies = @('module.azure.azapi_resource.identity')
        }
        if (-not $validation) { $instance.index_key = $name }
        $pair.Source.resources += @{
            module = 'module.azure'; mode = 'managed'; type = 'azapi_resource'
            name = $validation ? 'validation_federated_credential' : 'identity_federated_credentials'
            provider = 'provider["registry.terraform.io/azure/azapi"]'
            instances = @($instance)
        }
    }
    $federated = @($pair.Source.resources | Where-Object name -CEQ 'identity_federated_credentials')
    $federated[0].instances = @($federated | ForEach-Object { $_.instances })
    $pair.Source.resources = @($pair.Source.resources | Where-Object name -CNE 'identity_federated_credentials') + @($federated[0])
    $pair.Settings = New-AvmTestBamiSettings
    $pair.Settings.TEST_BAMI_MANAGEMENT_GROUP_ID = 'synthetic'
    $pair.Backend = @{
        TenantId = '20000000-0000-4000-8000-000000000001'
        SubscriptionId = '20000000-0000-4000-8000-000000000003'
        ClientId = '20000000-0000-4000-8000-000000000004'
        StorageAccountName = 'syntheticstate'
        ContainerName = 'repositories'
    }
    $pair.GitHubRepository = [pscustomobject]@{
        full_name = $pair.Repository; id = 1234; fork = $false
        owner = [pscustomobject]@{ id = 6844498; login = 'Azure' }
    }
    return $pair
}
