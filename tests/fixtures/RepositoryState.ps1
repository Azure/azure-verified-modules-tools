. (Join-Path $PSScriptRoot 'TestTenant.ps1')

function New-AvmTestRetainedRepositoryResources {
    @(
        @{
            mode = 'managed'; type = 'terraform_data'; name = 'retained'
            provider = 'provider["terraform.io/builtin/terraform"]'
            instances = @(@{
                schema_version = 0
                attributes = @{
                    id = '40000000-0000-4000-8000-000000000001'
                    input = @{ value = 'synthetic-retained-value'; type = 'string' }
                    output = @{ value = 'synthetic-retained-value'; type = 'string' }
                    triggers_replace = $null
                }
                sensitive_attributes = @()
                private = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('synthetic retained private data'))
                dependencies = @('module.github.github_repository.this')
            })
        }
        @{
            module = 'module.github.module.policy'; mode = 'managed'; type = 'github_repository_ruleset'; name = 'retained'
            provider = 'provider["registry.terraform.io/integrations/github"].retained'
            instances = @(@{
                schema_version = 0
                attributes = @{ id = '4567'; repository = 'terraform-azurerm-avm-ptn-example-repo'; name = 'synthetic-retained-ruleset' }
                sensitive_attributes = @()
            })
        }
    )
}

function New-AvmTestRepositoryStatePair {
    param(
        [string] $Repository = 'Azure/terraform-azurerm-avm-ptn-example-repo',
        [long] $RepositoryId = 1234
    )

    $resourceId = '/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/' + $repository.Replace('/', '-')
    $identity = @{
        identity_resource_id = $resourceId
        tenant_id = '10000000-0000-4000-8000-000000000001'
        client_id = '10000000-0000-4000-8000-000000000006'
        principal_id = '10000000-0000-4000-8000-000000000007'
        repository_id = [string]$RepositoryId
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
                    attributes = @{ id = $repository.Split('/')[1]; full_name = $repository; repo_id = $RepositoryId }
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
    param(
        [string] $Repository = 'Azure/terraform-azurerm-avm-ptn-example-repo',
        [long] $RepositoryId = 1234
    )

    $pair = New-AvmTestRepositoryStatePair -Repository $Repository -RepositoryId $RepositoryId
    foreach ($name in @('pr-check', 'integration-test', 'examples-test', 'avm-validation')) {
        $validation = $name -ceq 'avm-validation'
        $federatedRepositoryId = $validation ? '5678' : $pair.Identity.repository_id
        $subject = "repository_owner_id:$($pair.Identity.repository_owner_id):repository_id:${federatedRepositoryId}:environment:$name"
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
        full_name = $pair.Repository; id = $RepositoryId; fork = $false
        owner = [pscustomobject]@{ id = 6844498; login = 'Azure' }
    }
    return $pair
}

function New-AvmTestHistoricalRepositoryState {
    param(
        [string] $Repository,
        [long] $RepositoryId,
        [string] $OriginalRepository = $Repository,
        [switch] $CaseAlias
    )

    $repositoryName = $repository.Split('/')[1]
    $identityName = $originalRepository.Replace('/', '-')
    $tenant = '30000000-0000-4000-8000-000000000001'
    $subscription = '30000000-0000-4000-8000-000000000003'
    $principal = '30000000-0000-4000-8000-{0:000000000000}' -f $RepositoryId
    $group = '30000000-0000-4000-8000-000000000008'
    $roleName = '32000000-0000-4000-8000-{0:000000000000}' -f $RepositoryId
    $parent = "/subscriptions/$subscription/resourceGroups/rg-e2e-testing-module-identities"
    $identityId = "$parent/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$identityName"
    $roleParent = '/subscriptions/30000000-0000-4000-8000-000000000010'
    $entries = @(
        @{ Mode = 'data'; Type = 'azapi_client_config'; Name = 'current'; Attributes = @{ id = "clientConfigs/subscriptionId=$subscription;tenantId=$tenant"; tenant_id = $tenant; subscription_id = $subscription } }
        @{ Mode = 'data'; Type = 'azuread_group'; Name = 'entra_readers'; Attributes = @{ id = $group; object_id = $group } }
        @{ Mode = 'data'; Type = 'github_repository'; Name = 'this'; Attributes = @{ id = $originalRepository.Split('/')[1]; full_name = $repository; repo_id = $RepositoryId; node_id = "R_synthetic_$RepositoryId" } }
        @{ Mode = 'managed'; Type = 'azapi_resource'; Name = 'identity'; Attributes = @{
            id = $identityId; name = $identityName; parent_id = $parent
            type = 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview'
            output = @{ value = @{ properties = @{ tenantId = $tenant; principalId = $principal; clientId = '31000000-0000-4000-8000-{0:000000000000}' -f $RepositoryId } } }
        } }
        @{ Mode = 'managed'; Type = 'azapi_resource'; Name = 'identity_federated_credentials'; Attributes = @{
            id = "$identityId/federatedIdentityCredentials/$identityName"; name = $identityName; parent_id = $identityId
            type = 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview'
            body = @{ value = @{ properties = @{ issuer = 'https://token.actions.githubusercontent.com'; audiences = @('api://AzureADTokenExchange'); subject = "repo:${originalRepository}:environment:test" } } }
        } }
        @{ Mode = 'managed'; Type = 'azapi_resource'; Name = 'identity_role_assignment'; Attributes = @{
            id = "$roleParent/providers/Microsoft.Authorization/roleAssignments/$roleName"; name = $roleName; parent_id = $roleParent
            type = 'Microsoft.Authorization/roleAssignments@2022-04-01'
            body = @{ value = @{ properties = @{
                principalId = $principal; principalType = 'ServicePrincipal'
                roleDefinitionId = "$roleParent/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
            } } }
        } }
        @{ Mode = 'managed'; Type = 'azuread_group_member'; Name = 'example'; Attributes = @{ id = "$group/member/$principal"; group_object_id = $group; member_object_id = $principal } }
        @{ Mode = 'managed'; Type = 'github_repository_environment'; Name = 'this'; Index = 0; Attributes = @{ id = "${repositoryName}:test"; repository = $repositoryName; environment = 'test' } }
    )
    $teams = $CaseAlias ? @('avm_core', 'contributors', 'owners') : @('avm_core')
    foreach ($name in $teams) {
        $entries += @{ Mode = 'data'; Type = 'github_team'; Name = $name; Index = 0; Attributes = @{ id = "synthetic-$name" } }
    }
    foreach ($name in @('client_id', 'subscription_id', 'tenant_id')) {
        $secret = 'ARM_' + $name.ToUpperInvariant()
        $entries += @{
            Mode = 'managed'; Type = 'github_actions_environment_secret'; Name = $name; Index = 0
            Attributes = @{ id = "${repositoryName}:test:$secret"; repository = $repositoryName; environment = 'test'; secret_name = $secret; plaintext_value = 'synthetic-private-value-never-logged' }
        }
    }
    $resources = foreach ($entry in $entries) {
        $provider = $entry.Type.StartsWith('azapi_') ? 'azure/azapi' : ($entry.Type.StartsWith('azuread_') ? 'hashicorp/azuread' : 'integrations/github')
        $instance = @{
            schema_version = $entry.Type -ceq 'azapi_resource' ? 2 : 0
            attributes = $entry.Attributes; sensitive_attributes = @()
            private = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('synthetic historical opaque private data'))
        }
        if ($entry.ContainsKey('Index')) { $instance.index_key = $entry.Index }
        @{ mode = $entry.Mode; type = $entry.Type; name = $entry.Name; provider = 'provider["registry.terraform.io/' + $provider + '"]'; instances = @($instance) }
    }
    $legacy = @{
        version = 4; terraform_version = $CaseAlias ? '1.10.5' : '1.11.2'
        serial = 453; lineage = '33000000-0000-4000-8000-{0:000000000000}' -f $RepositoryId
        outputs = @{}; resources = @($resources); check_results = $null
    }
    if (-not $CaseAlias) {
        $labels = foreach ($index in 1..43) {
            $label = "synthetic-label-$index"
            @{ index_key = $label; schema_version = 0; sensitive_attributes = @(); attributes = @{ id = "${repositoryName}:$label"; repository = $repositoryName; name = $label } }
        }
        $legacy.resources += @(
            @{
                mode = 'managed'; type = 'github_issue_label'; name = 'this'
                provider = 'provider["registry.terraform.io/integrations/github"]'; instances = @($labels)
            }
            @{
                mode = 'managed'; type = 'github_repository_ruleset'; name = 'main'
                provider = 'provider["registry.terraform.io/integrations/github"]'
                instances = @(@{ schema_version = 0; sensitive_attributes = @(); attributes = @{ id = [string](1000000 + $RepositoryId); repository = $repositoryName } })
            }
        )
    }
    return $legacy
}

function New-AvmTestLegacyAliasStatePair {
    $repository = 'Azure/terraform-azurerm-avm-res-redhatopenshift-openshiftcluster'
    $repositoryName = $repository.Split('/')[1]
    $legacy = New-AvmTestHistoricalRepositoryState -Repository $repository -RepositoryId 5679 -CaseAlias `
        -OriginalRepository 'Azure/terraform-azurerm-avm-res-redhatopenShift-openshiftcluster'
    $canonical = New-AvmTestMigrationStatePair -Repository $repository -RepositoryId 5679
    $canonical.Destination.resources = @($canonical.Destination.resources | Where-Object module -CEQ 'module.github')
    $canonical.Destination.resources[0].instances[0].attributes.node_id = 'R_synthetic_5679'
    $single = @{
        'github_actions_repository_oidc_subject_claim_customization_template.this' = $repositoryName
        'github_actions_secret.arm_client_id' = "${repositoryName}:ARM_CLIENT_ID"
        'github_actions_secret.arm_tenant_id' = "${repositoryName}:ARM_TENANT_ID"
        'github_actions_secret.test_subscription_ids' = "${repositoryName}:TEST_SUBSCRIPTION_IDS"
        'github_actions_variable.copilot_firewall_allow_list' = "${repositoryName}:COPILOT_AGENT_FIREWALL_ALLOW_LIST_ADDITIONS"
        'github_dependabot_secret.arm_client_id' = "${repositoryName}:ARM_CLIENT_ID"
        'github_dependabot_secret.arm_tenant_id' = "${repositoryName}:ARM_TENANT_ID"
        'github_dependabot_secret.test_subscription_ids' = "${repositoryName}:TEST_SUBSCRIPTION_IDS"
        'github_repository_custom_property.default_opt_in' = "${repositoryName}:default_opt_in"
        'github_repository_custom_property.global_opt_out' = "${repositoryName}:global_opt_out"
        'github_repository_custom_property.prod_opt_in' = "${repositoryName}:prod_opt_in"
        'github_repository_dependabot_security_updates.this' = $repositoryName
        'github_repository_environment.no_approval' = "${repositoryName}:no-approval"
        'github_repository_ruleset.main' = '56790001'
        'github_repository_ruleset.tag_deny_non_v' = '56790002'
        'github_repository_ruleset.tag_prevent_delete_version_tags' = '56790003'
        'github_repository_vulnerability_alerts.this' = $repositoryName
    }
    foreach ($entry in $single.GetEnumerator()) {
        $parts = $entry.Key.Split('.')
        $canonical.Destination.resources += @{
            module = 'module.github'; mode = 'managed'; type = $parts[0]; name = $parts[1]
            provider = 'provider["registry.terraform.io/integrations/github"]'
            instances = @(@{ schema_version = 0; attributes = @{ id = $entry.Value; repository = $repositoryName }; sensitive_attributes = @() })
        }
    }
    foreach ($entry in @(
        @{ Type = 'github_issue_label'; Name = 'this'; Mode = 'managed'; Indexes = @(1..45 | ForEach-Object { "synthetic-label-$_" }) }
        @{ Type = 'github_repository_environment'; Name = 'approval'; Mode = 'managed'; Indexes = @('examples-test', 'integration-test', 'pr-check') }
        @{ Type = 'github_team_repository'; Name = 'this'; Mode = 'managed'; Indexes = @('owners', 'contributors', 'readers', 'engineering') }
        @{ Type = 'github_team'; Name = 'this'; Mode = 'data'; Indexes = @('owners', 'contributors', 'readers', 'engineering') }
        @{ Type = 'github_organization'; Name = 'this'; Mode = 'data'; Indexes = @('Azure') }
    )) {
        $instances = foreach ($index in $entry.Indexes) {
            @{ index_key = $index; schema_version = 0; attributes = @{ id = "${repositoryName}:$index"; repository = $repositoryName }; sensitive_attributes = @() }
        }
        $canonical.Destination.resources += @{
            module = 'module.github'; mode = $entry.Mode; type = $entry.Type; name = $entry.Name
            provider = 'provider["registry.terraform.io/integrations/github"]'; instances = @($instances)
        }
    }
    return @{
        Legacy = $legacy; Canonical = $canonical
        LegacyKey = 'avm-res-redhatopenShift-openshiftcluster.tfstate'
        CanonicalKey = 'avm-res-redhatopenshift-openshiftcluster.tfstate'
    }
}
