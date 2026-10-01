#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:subscription = '00000000-0000-0000-0000-000000000001'
    $script:runId = '0123456789abcdef0123456789abcdef'
    $script:group = "avm-e2e-$script:runId"
    $script:resourceId = "/subscriptions/$script:subscription/resourceGroups/$script:group/providers/Microsoft.Storage/storageAccounts/demo"
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep direct-group resource identity' {
    It 'parses a nested group resource into its exact type and full name' {
        $id = "/subscriptions/$script:subscription/resourceGroups/$script:group/providers/Microsoft.Network/virtualNetworks/demo/subnets/backend"
        $resource = InModuleScope 'Avm.Authoring' -Parameters @{
            Id = $id; S = $script:subscription; G = $script:group; R = $script:runId
        } {
            param($Id, $S, $G, $R)
            Get-AvmBicepTestGroupResource -ResourceId $Id -SubscriptionId $S `
                -ResourceGroupName $G -RunId $R
        }
        $resource.Type | Should -BeExactly 'Microsoft.Network/virtualNetworks/subnets'
        $resource.Name | Should -BeExactly 'demo/backend'
        $resource.GroupName | Should -BeExactly $script:group
    }

    It 'refuses an unowned or ambiguous <Case> resource ID' -ForEach @(
        @{ Case = 'foreign subscription'; Mutation = 'subscription'; Message = '*outside its run-owned group*' }
        @{ Case = 'foreign group'; Mutation = 'group'; Message = '*outside its run-owned group*' }
        @{ Case = 'nested provider extension'; Mutation = 'extension'; Message = '*uninspectable group resource ID*' }
        @{ Case = 'encoded path separator'; Mutation = 'encoded'; Message = '*uninspectable group resource ID*' }
        @{ Case = 'authorization write'; Mutation = 'authorization'; Message = '*prohibited group resource type*' }
    ) {
        $id = switch ($Mutation) {
            subscription {
                $script:resourceId.Replace($script:subscription,
                    '00000000-0000-0000-0000-000000000002')
            }
            group { $script:resourceId.Replace($script:group, 'foreign') }
            extension { "$script:resourceId/providers/Microsoft.Authorization/locks/external" }
            encoded { $script:resourceId.Replace('demo', 'demo%2Fother') }
            authorization {
                $script:resourceId.Replace('Microsoft.Storage/storageAccounts',
                    'Microsoft.Authorization/roleAssignments')
            }
        }
        InModuleScope 'Avm.Authoring' -Parameters @{
            Id = $id; S = $script:subscription; G = $script:group; R = $script:runId
            Expected = $Message
        } {
            param($Id, $S, $G, $R, $Expected)
            { Get-AvmBicepTestGroupResource -ResourceId $Id -SubscriptionId $S `
                    -ResourceGroupName $G -RunId $R } |
                Should -Throw -ExpectedMessage $Expected
        }
    }
}

Describe 'Bicep direct-group full-payload preview' {
    BeforeEach {
        $script:template = @{
            resources = @(@{ type = 'Microsoft.Storage/storageAccounts'; name = 'demo' })
        }
        $script:preview = @{
            changes = @(@{
                    resourceId = $script:resourceId
                    changeType = 'Create'
                    after = @{
                        type = 'Microsoft.Storage/storageAccounts'
                        name = 'demo'
                    }
                })
        }
    }

    It 'accepts only the declared, expanded Create at the selected run-owned group' {
        $plan = InModuleScope 'Avm.Authoring' -Parameters @{
            Template = $script:template
            Output = ($script:preview | ConvertTo-Json -Depth 16 -Compress)
            S = $script:subscription; G = $script:group; R = $script:runId
        } {
            param($Template, $Output, $S, $G, $R)
            Read-AvmBicepTestGroupWhatIf -Output $Output -File 'defaults' `
                -Template $Template -SubscriptionId $S -ResourceGroupName $G -RunId $R
        }
        $plan.Resources.Count | Should -Be 1
        $plan.Resources[0].Id | Should -BeExactly $script:resourceId
        $plan.Resources[0].Type | Should -BeExactly 'Microsoft.Storage/storageAccounts'
        $plan.Deployments.Count | Should -Be 0
    }

    It 'refuses <Case> before ARM Create' -ForEach @(
        @{ Case = 'Ignore'; Mutation = 'ignore'; Message = '*non-Create*' }
        @{ Case = 'Deploy'; Mutation = 'deploy'; Message = '*non-Create*' }
        @{ Case = 'NoChange'; Mutation = 'unchanged'; Message = '*non-Create*' }
        @{ Case = 'Modify'; Mutation = 'modify'; Message = '*non-Create*' }
        @{ Case = 'Delete'; Mutation = 'delete'; Message = '*non-Create*' }
        @{ Case = 'duplicate changes'; Mutation = 'duplicate'; Message = '*duplicate change*' }
        @{ Case = 'missing full payload'; Mutation = 'after'; Message = '*full resource payload*' }
        @{ Case = 'mismatched type'; Mutation = 'type'; Message = '*full resource payload*' }
        @{ Case = 'mismatched name'; Mutation = 'name'; Message = '*full resource payload*' }
        @{ Case = 'mismatched ID'; Mutation = 'id'; Message = '*full resource payload*' }
        @{ Case = 'unapproved type'; Mutation = 'undeclared'; Message = '*undeclared resource type*' }
        @{ Case = 'unapproved literal name'; Mutation = 'literal-name'; Message = '*undeclared literal name*' }
        @{ Case = 'foreign group'; Mutation = 'foreign'; Message = '*outside its run-owned group*' }
        @{ Case = 'foreign ownership tag'; Mutation = 'tag'; Message = '*foreign or ambiguous ownership tags*' }
        @{ Case = 'case-variant ownership tag'; Mutation = 'case-tag'; Message = '*foreign or ambiguous ownership tags*' }
        @{ Case = 'cross-scope payload'; Mutation = 'scope'; Message = '*cross-scope scope*' }
    ) {
        switch ($Mutation) {
            ignore { $script:preview.changes[0].changeType = 'Ignore' }
            deploy { $script:preview.changes[0].changeType = 'Deploy' }
            unchanged { $script:preview.changes[0].changeType = 'NoChange' }
            modify { $script:preview.changes[0].changeType = 'Modify' }
            delete { $script:preview.changes[0].changeType = 'Delete' }
            duplicate { $script:preview.changes += $script:preview.changes[0] }
            after { $null = $script:preview.changes[0].Remove('after') }
            type { $script:preview.changes[0].after.type = 'Microsoft.Network/routeTables' }
            name { $script:preview.changes[0].after.name = 'other' }
            id { $script:preview.changes[0].after.id = '/subscriptions/foreign' }
            undeclared {
                $script:preview.changes[0].resourceId = $script:resourceId.Replace(
                    'Microsoft.Storage/storageAccounts', 'Microsoft.Network/routeTables')
                $script:preview.changes[0].after.type = 'Microsoft.Network/routeTables'
            }
            'literal-name' {
                $script:preview.changes[0].resourceId =
                    $script:resourceId.Replace('/demo', '/other')
                $script:preview.changes[0].after.name = 'other'
            }
            foreign {
                $script:preview.changes[0].resourceId =
                    $script:resourceId.Replace($script:group, 'foreign')
            }
            tag { $script:preview.changes[0].after.tags = @{ 'avm-e2e-run-id' = 'foreign' } }
            'case-tag' {
                $script:preview.changes[0].after.tags = @{ 'AVM-E2E-RUN-ID' = $script:runId }
            }
            scope { $script:preview.changes[0].after.scope = '/subscriptions/foreign' }
        }
        InModuleScope 'Avm.Authoring' -Parameters @{
            Template = $script:template
            Output = ($script:preview | ConvertTo-Json -Depth 16 -Compress)
            S = $script:subscription; G = $script:group; R = $script:runId
            Expected = $Message
        } {
            param($Template, $Output, $S, $G, $R, $Expected)
            { Read-AvmBicepTestGroupWhatIf -Output $Output -File 'defaults' `
                    -Template $Template -SubscriptionId $S -ResourceGroupName $G -RunId $R } |
                Should -Throw -ExpectedMessage $Expected
        }
    }

    It 'accepts an ARM-resolved name for an authored parameter expression' {
        $script:template.resources[0].name = "[parameters('accountName')]"
        $plan = InModuleScope 'Avm.Authoring' -Parameters @{
            Template = $script:template
            Output = ($script:preview | ConvertTo-Json -Depth 16 -Compress)
            S = $script:subscription; G = $script:group; R = $script:runId
        } {
            param($Template, $Output, $S, $G, $R)
            Read-AvmBicepTestGroupWhatIf -Output $Output -File 'defaults' `
                -Template $Template -SubscriptionId $S -ResourceGroupName $G -RunId $R
        }
        $plan.Resources[0].Name | Should -BeExactly 'demo'
    }

    It 'inspects an inline group deployment and its child Create without an external template' {
        $schema = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        $nested = @{ '$schema' = $schema; resources = $script:template.resources }
        $script:template = @{
            resources = @(@{
                    type = 'Microsoft.Resources/deployments'
                    name = 'inner'
                    properties = @{ mode = 'Incremental'; template = $nested }
                })
        }
        $deploymentId = "/subscriptions/$script:subscription/resourceGroups/$script:group/providers/Microsoft.Resources/deployments/inner"
        $script:preview.changes = @(
            @{
                resourceId = $deploymentId
                changeType = 'Create'
                after = @{
                    name = 'inner'; type = 'Microsoft.Resources/deployments'
                    properties = @{ mode = 'Incremental'; template = $nested }
                }
            }
            $script:preview.changes[0]
        )
        $plan = InModuleScope 'Avm.Authoring' -Parameters @{
            Template = $script:template
            Output = ($script:preview | ConvertTo-Json -Depth 16 -Compress)
            S = $script:subscription; G = $script:group; R = $script:runId
        } {
            param($Template, $Output, $S, $G, $R)
            Read-AvmBicepTestGroupWhatIf -Output $Output -File 'defaults' `
                -Template $Template -SubscriptionId $S -ResourceGroupName $G -RunId $R
        }
        $plan.Resources.Count | Should -Be 1
        $plan.Deployments.Count | Should -Be 1
        $plan.Deployments[0].Id | Should -BeExactly $deploymentId
    }
}
