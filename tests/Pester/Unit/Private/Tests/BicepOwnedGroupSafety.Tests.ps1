#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:subscription = '00000000-0000-0000-0000-000000000001'
    $script:runId = '0123456789abcdef0123456789abcdef'
    $script:fixturePath = Join-Path `
        (Split-Path -Parent (Split-Path -Parent $script:moduleRoot)) `
        'tests' 'fixtures' 'bicep-scoped' 'route-table-defaults.6eb8e6ff.json'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep subscription-to-owned-group static safety' {
    It 'recognizes the pinned real compiler shape but refuses its conditional authorization effects' {
        $template = Get-Content -LiteralPath $script:fixturePath -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable
        $template.metadata._generator.version | Should -Be '0.47.16.16243'
        $template.resources[0].type | Should -BeExactly 'Microsoft.Resources/resourceGroups'
        $template.resources[0].Contains('tags') | Should -BeFalse
        $template.resources[1].resourceGroup | Should -BeExactly $template.resources[0].name
        $template.resources[1].properties.template.languageVersion | Should -BeExactly '2.0'

        InModuleScope 'Avm.Authoring' -Parameters @{
            Template = $template; RunId = $script:runId
        } {
            param($Template, $RunId)
            $staged = Set-AvmBicepTestGroupOwnership -Template $Template `
                -RunId $RunId -SourcePath 'pinned-route-table.bicep'
            $staged.Tagged | Should -BeTrue
            $staged.HasGroupDeployment | Should -BeTrue
            $Template.resources[0].tags['avm-e2e-run-id'] | Should -BeExactly $RunId
            { Assert-AvmBicepScopedTestIsolation -Template $Template -Scope sub `
                    -SourcePath 'pinned-route-table.bicep' -OwnedGroupRunId $RunId } |
                Should -Throw -ExpectedMessage '*cross-scope resource (scope)*'
        }
    }

    It 'inspects the explicitly reduced, unprivileged subset of the pinned inline group template' {
        $template = Get-Content -LiteralPath $script:fixturePath -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable
        $nested = $template.resources[1].properties.template.resources
        $null = $nested.Remove('routeTable_lock')
        $null = $nested.Remove('routeTable_roleAssignments')
        InModuleScope 'Avm.Authoring' -Parameters @{
            Template = $template; RunId = $script:runId
        } {
            param($Template, $RunId)
            $null = Set-AvmBicepTestGroupOwnership -Template $Template `
                -RunId $RunId -SourcePath 'reduced-route-table.bicep'
            { Assert-AvmBicepScopedTestIsolation -Template $Template -Scope sub `
                    -SourcePath 'reduced-route-table.bicep' -OwnedGroupRunId $RunId } |
                Should -Not -Throw
        }
    }

    It 'refuses malformed <Case> in a reduced pinned template' -ForEach @(
        @{ Case = 'foreign target'; Mutation = 'group'; Expected = '*unverified or repeated group deployment*' }
        @{ Case = 'foreign subscription'; Mutation = 'subscription'; Expected = '*cross-scope resource (subscriptionId)*' }
        @{ Case = 'missing group dependency'; Mutation = 'dependency'; Expected = '*unverified or repeated group deployment*' }
        @{ Case = 'repeated deployment'; Mutation = 'copy'; Expected = '*unverified or repeated group deployment*' }
        @{ Case = 'management-group template'; Mutation = 'schema'; Expected = '*inline resource-group template*' }
        @{ Case = 'foreign run tag'; Mutation = 'tag'; Expected = '*unconditional run-owned group*' }
        @{ Case = 'unreviewed script'; Mutation = 'script'; Expected = '*unsupported group resource type*' }
        @{ Case = 'unreviewed lock'; Mutation = 'lock'; Expected = '*unsupported group resource type*' }
        @{ Case = 'unreviewed role assignment'; Mutation = 'assignment'; Expected = '*unsupported group resource type*' }
        @{ Case = 'linked template'; Mutation = 'link'; Expected = '*inline template*' }
        @{ Case = 'external nested parameter'; Mutation = 'parameter-reference'; Expected = '*uninspectable group deployment parameter*' }
        @{ Case = 'multiple groups'; Mutation = 'multiple'; Expected = '*exactly one new group*' }
    ) {
        $template = Get-Content -LiteralPath $script:fixturePath -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable
        $group = $template.resources[0]
        $deployment = $template.resources[1]
        $nested = $deployment.properties.template.resources
        $null = $nested.Remove('routeTable_lock')
        $null = $nested.Remove('routeTable_roleAssignments')
        InModuleScope 'Avm.Authoring' -Parameters @{
            Template = $template; RunId = $script:runId
            Change = $Mutation; Message = $Expected
        } {
            param($Template, $RunId, $Change, $Message)
            $null = Set-AvmBicepTestGroupOwnership -Template $Template `
                -RunId $RunId -SourcePath 'reduced-route-table.bicep'
            $group = $Template.resources[0]
            $deployment = $Template.resources[1]
            $nested = $deployment.properties.template.resources
            switch ($Change) {
                group { $deployment.resourceGroup = "[parameters('anotherGroup')]" }
                subscription { $deployment.subscriptionId = '[subscription().subscriptionId]' }
                dependency { $deployment.dependsOn = @() }
                copy { $deployment.copy = @{ name = 'iteration'; count = 2 } }
                schema {
                    $deployment.properties.template['$schema'] =
                        'https://schema.management.azure.com/schemas/2019-08-01/managementGroupDeploymentTemplate.json#'
                }
                tag { $group.tags['avm-e2e-run-id'] = 'another-run' }
                script { $nested.routeTable.type = 'Microsoft.Resources/deploymentScripts' }
                lock {
                    $nested.extra = @{ type = 'Microsoft.Authorization/locks' }
                }
                assignment {
                    $nested.extra = @{ type = 'Microsoft.Authorization/roleAssignments' }
                }
                link { $deployment.properties.templateLink = @{ uri = 'https://example.invalid' } }
                'parameter-reference' {
                    $deployment.properties.parameters.name = @{
                        reference = @{ keyVault = @{ id = '/subscriptions/other' }; secretName = 'key' }
                    }
                }
                multiple {
                    $Template.resources += @{ type = 'Microsoft.Resources/resourceGroups'; name = 'other' }
                }
            }

            { Assert-AvmBicepScopedTestIsolation -Template $Template -Scope sub `
                    -SourcePath 'reduced-route-table.bicep' -OwnedGroupRunId $RunId } |
                Should -Throw -ExpectedMessage $Message
        }
    }

    It 'preserves authored group tags and refuses dynamic, conflicting or duplicate ownership tags' {
        InModuleScope 'Avm.Authoring' -Parameters @{ RunId = $script:runId } {
            param($RunId)
            $template = @{ resources = @(@{
                        type = 'Microsoft.Resources/resourceGroups'
                        name = "[parameters('resourceGroupName')]"
                        tags = @{ owner = 'author' }
                    }) }
            $null = Set-AvmBicepTestGroupOwnership -Template $template `
                -RunId $RunId -SourcePath 'case.bicep'
            $template.resources[0].tags.owner | Should -BeExactly 'author'
            $template.resources[0].tags['avm-e2e-run-id'] | Should -BeExactly $RunId

            $template.resources[0].tags = "[parameters('tags')]"
            { Set-AvmBicepTestGroupOwnership -Template $template `
                    -RunId $RunId -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage '*dynamic group tags*'
            $template.resources[0].tags = @{ 'avm-e2e-run-id' = 'foreign-run' }
            { Set-AvmBicepTestGroupOwnership -Template $template `
                    -RunId $RunId -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage '*different group ownership tag*'
            $tags = [System.Collections.Specialized.OrderedDictionary]::new(
                [System.StringComparer]::Ordinal)
            $tags.Add('avm-e2e-run-id', $RunId)
            $tags.Add('AVM-E2E-RUN-ID', $RunId)
            $template.resources[0].tags = $tags
            { Set-AvmBicepTestGroupOwnership -Template $template `
                    -RunId $RunId -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage '*ambiguous or nonliteral group tags*'
        }
    }
}

Describe 'Bicep run-owned group expanded what-if' {
    BeforeEach {
        $compiled = Get-Content -LiteralPath $script:fixturePath -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable
        $nested = $compiled.resources[1].properties.template.resources
        $null = $nested.Remove('routeTable_lock')
        $null = $nested.Remove('routeTable_roleAssignments')
        $suffix = $script:runId.Substring(0, 10)
        $script:groupName = "team$suffix-rg"
        $script:groupId = "/subscriptions/$script:subscription/resourceGroups/$script:groupName"
        $script:deploymentId = "$script:groupId/providers/Microsoft.Resources/deployments/inner-$suffix"
        $script:resourceId = "$script:groupId/providers/Microsoft.Network/routeTables/team${suffix}nrtmin001"
        $script:preview = @{
            changes = @(
                @{
                    changeType = 'Create'
                    resourceId = $script:groupId
                    after = @{
                        name = $script:groupName
                        type = 'Microsoft.Resources/resourceGroups'
                        tags = @{ 'avm-e2e-run-id' = $script:runId }
                    }
                }
                @{
                    changeType = 'Create'
                    resourceId = $script:deploymentId
                    after = @{
                        name = "inner-$suffix"
                        type = 'Microsoft.Resources/deployments'
                        properties = @{
                            mode = 'Incremental'
                            template = $compiled.resources[1].properties.template
                        }
                    }
                }
                @{
                    changeType = 'Create'
                    resourceId = $script:resourceId
                    after = @{
                        name = "team${suffix}nrtmin001"
                        type = 'Microsoft.Network/routeTables'
                    }
                }
            )
        }
    }

    It 'binds a custom run-unique prefix to exactly one group, nested deployment and route table' {
        $plan = InModuleScope 'Avm.Authoring' -Parameters @{
            Output = ($script:preview | ConvertTo-Json -Depth 100 -Compress)
            S = $script:subscription; R = $script:runId
        } {
            param($Output, $S, $R)
            Read-AvmBicepScopedWhatIf -Output $Output -File 'route-table/defaults' `
                -Scope sub -SubscriptionId $S -RunId $R -RequireOwnedGroup
        }
        $plan.OwnedGroupName | Should -BeExactly $script:groupName
        $plan.Resources.Count | Should -Be 2
        $plan.Deployments.Count | Should -Be 1
        $plan.Resources[0].Kind | Should -BeExactly 'Group'
        $plan.Resources[1].Type | Should -BeExactly 'Microsoft.Network/routeTables'
        $plan.Resources[1].GroupName | Should -BeExactly $script:groupName
        $plan.Deployments[0].GroupName | Should -BeExactly $script:groupName
    }

    It 'accepts the pinned telemetry-only inline template as an additional group deployment' {
        $telemetry = $script:preview.changes[1].after.properties.template.resources.avmTelemetry
        $script:preview.changes += @{
            changeType = 'Create'
            resourceId = "$script:groupId/providers/Microsoft.Resources/deployments/telemetry-0123456789"
            after = @{
                name = 'telemetry-0123456789'
                type = 'Microsoft.Resources/deployments'
                properties = @{ mode = 'Incremental'; template = $telemetry.properties.template }
            }
        }
        $plan = InModuleScope 'Avm.Authoring' -Parameters @{
            Output = ($script:preview | ConvertTo-Json -Depth 100 -Compress)
            S = $script:subscription; R = $script:runId
        } {
            param($Output, $S, $R)
            Read-AvmBicepScopedWhatIf -Output $Output -File 'route-table/defaults' `
                -Scope sub -SubscriptionId $S -RunId $R -RequireOwnedGroup
        }
        $plan.Deployments.Count | Should -Be 2
        $script:preview.changes[3].after.properties.template.outputs.telemetry.value = 'foreign output'
        InModuleScope 'Avm.Authoring' -Parameters @{
            Output = ($script:preview | ConvertTo-Json -Depth 100 -Compress)
            S = $script:subscription; R = $script:runId
        } {
            param($Output, $S, $R)
            { Read-AvmBicepScopedWhatIf -Output $Output -File 'route-table/defaults' `
                    -Scope sub -SubscriptionId $S -RunId $R -RequireOwnedGroup } |
                Should -Throw -ExpectedMessage '*telemetry-only*'
        }
    }

    It 'refuses <Case> rather than treating the preview as a safe Create' -ForEach @(
        @{ Case = 'Ignore'; Mutation = 'ignore'; Expected = '*non-Create*' }
        @{ Case = 'Deploy'; Mutation = 'deploy'; Expected = '*non-Create*' }
        @{ Case = 'NoChange'; Mutation = 'unchanged'; Expected = '*non-Create*' }
        @{ Case = 'Modify'; Mutation = 'modify'; Expected = '*non-Create*' }
        @{ Case = 'Delete'; Mutation = 'delete'; Expected = '*non-Create*' }
        @{ Case = 'missing nested expansion'; Mutation = 'missing-template'; Expected = '*did not expand inline group deployment*' }
        @{ Case = 'linked nested expansion'; Mutation = 'linked-template'; Expected = '*did not expand inline group deployment*' }
        @{ Case = 'foreign expanded scope'; Mutation = 'scope'; Expected = '*unexpected scope*' }
        @{ Case = 'foreign expanded group'; Mutation = 'resource-group'; Expected = '*foreign group target*' }
        @{ Case = 'foreign route ownership tag'; Mutation = 'route-tag'; Expected = '*unverified ownership tags*' }
        @{ Case = 'case-variant route ownership tag'; Mutation = 'route-tag-case'; Expected = '*ambiguous ownership tags*' }
        @{ Case = 'unverified deployment mode'; Mutation = 'array-mode'; Expected = '*did not expand inline group deployment*' }
        @{ Case = 'nested template at another scope'; Mutation = 'nested-schema'; Expected = '*non-group nested template*' }
        @{ Case = 'expanded nested Key Vault parameter'; Mutation = 'nested-reference'; Expected = '*uninspectable group deployment parameter*' }
        @{ Case = 'unreviewed nested deployment property'; Mutation = 'nested-property'; Expected = '*unsupported nested deployment property*' }
        @{ Case = 'another resource group'; Mutation = 'foreign-group'; Expected = '*outside the explicit sub target*' }
        @{ Case = 'another subscription'; Mutation = 'foreign-sub'; Expected = '*outside the explicit sub target*' }
        @{ Case = 'untagged group'; Mutation = 'tag'; Expected = '*exact avm-e2e-run-id*' }
        @{ Case = 'unchanging custom prefix'; Mutation = 'static-name'; Expected = '*per-case run suffix*' }
        @{ Case = 'unapproved resource'; Mutation = 'type'; Expected = '*unsupported type*' }
        @{ Case = 'subscription-level extra resource'; Mutation = 'extra'; Expected = '*outside the explicit sub target*' }
        @{ Case = 'missing group module'; Mutation = 'missing-module'; Expected = '*lacks an owned group*' }
    ) {
        switch ($Mutation) {
            ignore { $script:preview.changes[2].changeType = 'Ignore' }
            deploy { $script:preview.changes[1].changeType = 'Deploy' }
            unchanged { $script:preview.changes[2].changeType = 'NoChange' }
            modify { $script:preview.changes[0].changeType = 'Modify' }
            delete { $script:preview.changes[2].changeType = 'Delete' }
            'missing-template' {
                $null = $script:preview.changes[1].after.properties.Remove('template')
            }
            'linked-template' {
                $null = $script:preview.changes[1].after.properties.Remove('template')
                $script:preview.changes[1].after.properties.templateLink = @{
                    uri = 'https://example.invalid'
                }
            }
            scope { $script:preview.changes[2].after.scope = '/providers/Microsoft.Management/managementGroups/foreign' }
            'resource-group' { $script:preview.changes[2].after.resourceGroup = 'foreign-rg' }
            'route-tag' {
                $script:preview.changes[2].after.tags = @{ 'avm-e2e-run-id' = 'foreign' }
            }
            'route-tag-case' {
                $script:preview.changes[2].after.tags = @{ 'AVM-E2E-RUN-ID' = 'foreign' }
            }
            'array-mode' { $script:preview.changes[1].after.properties.mode = @('Incremental') }
            'nested-schema' {
                $script:preview.changes[1].after.properties.template['$schema'] =
                    'https://schema.management.azure.com/schemas/2019-08-01/tenantDeploymentTemplate.json#'
            }
            'nested-reference' {
                $script:preview.changes[1].after.properties.parameters = @{
                    name = @{ reference = @{ keyVault = @{ id = '/subscriptions/foreign' } } }
                }
            }
            'nested-property' {
                $script:preview.changes[1].after.properties.onErrorDeployment = @{
                    type = 'LastSuccessful'
                }
            }
            'foreign-group' {
                $script:preview.changes[2].resourceId =
                    $script:resourceId.Replace($script:groupName, 'other-group')
            }
            'foreign-sub' {
                $script:preview.changes[2].resourceId =
                    $script:resourceId.Replace($script:subscription,
                        '00000000-0000-0000-0000-000000000003')
            }
            tag { $script:preview.changes[0].after.tags['avm-e2e-run-id'] = 'foreign' }
            'static-name' {
                $script:preview.changes[2].resourceId =
                    $script:resourceId.Replace('team0123456789nrtmin001', 'static-route')
                $script:preview.changes[2].after.name = 'static-route'
            }
            type {
                $script:preview.changes[2].resourceId =
                    $script:resourceId.Replace('Microsoft.Network/routeTables',
                        'Microsoft.Authorization/roleAssignments')
                $script:preview.changes[2].after.type = 'Microsoft.Authorization/roleAssignments'
            }
            extra {
                $script:preview.changes += @{
                    changeType = 'Create'
                    resourceId = "/subscriptions/$script:subscription/providers/Microsoft.Authorization/policyDefinitions/team0123456789-extra"
                    after = @{
                        name = 'team0123456789-extra'
                        type = 'Microsoft.Authorization/policyDefinitions'
                    }
                }
            }
            'missing-module' {
                $script:preview.changes = @($script:preview.changes[0], $script:preview.changes[2])
            }
        }
        InModuleScope 'Avm.Authoring' -Parameters @{
            Output = ($script:preview | ConvertTo-Json -Depth 100 -Compress)
            S = $script:subscription; R = $script:runId
            Expected = $Expected
        } {
            param($Output, $S, $R, $Expected)
            { Read-AvmBicepScopedWhatIf -Output $Output -File 'route-table/defaults' `
                    -Scope sub -SubscriptionId $S -RunId $R -RequireOwnedGroup } |
                Should -Throw -ExpectedMessage $Expected
        }
    }
}
