BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')

    function New-AvmTestBamiSummaryPlan {
        param([switch] $KnownClient, [switch] $ValidationPending)

        $plan = New-AvmTestBamiPlan -KnownClient:$KnownClient -ValidationPending:$ValidationPending `
            -RepositoryOwnerId '5678' -RepositorySyncRepositoryId '9012'
        $identity = New-AvmTestBamiIdentity
        $principalId = '10000000-0000-4000-8000-000000000007'
        $groupId = '10000000-0000-4000-8000-000000000008'
        $plan.planned_values.outputs.test_identity.value.repository_owner_id = '5678'
        $resources = $plan.planned_values.root_module.child_modules[0].resources
        $resources[0].values.type = 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview'
        $resources[1].values.type = 'Microsoft.Authorization/roleAssignments@2022-04-01'
        if ($KnownClient) {
            $resources[0].values.id = $identity.identity_resource_id
            $resources[0].values.output = @{
                properties = @{
                    tenantId = $identity.tenant_id
                    clientId = $identity.client_id
                    principalId = $principalId
                }
            }
            $resources[1].values.body.properties.principalId = $principalId
            $resources[2].values.member_object_id = $principalId
        }
        $resources[1].values.body.properties.principalType = 'ServicePrincipal'
        $resources[2].values.group_object_id = $groupId
        foreach ($environment in @('pr-check', 'integration-test', 'examples-test')) {
            $address = 'module.azure.azapi_resource.identity_federated_credentials["' + $environment + '"]'
            $resource = @($resources | Where-Object { $_.address -ceq $address })[0]
            $resource.values = @{
                type = 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview'
                name = $resources[0].values.name + "-$environment"
                parent_id = if ($KnownClient) { $identity.identity_resource_id } else { $null }
                body = @{
                    properties = @{
                        issuer = 'https://token.actions.githubusercontent.com'
                        audiences = @('api://AzureADTokenExchange')
                        subject = "repository_owner_id:5678:repository_id:1234:environment:${environment}:job_workflow_ref:Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main"
                    }
                }
            }
        }
        foreach ($resource in $resources) {
            $resource.sensitive_values = @{}
            $change = @($plan.resource_changes | Where-Object { $_.address -ceq $resource.address })[0].change
            $change.after = $resource.values.Clone()
            $change.after_sensitive = @{}
            $change.after_unknown = @{}
            if (-not $KnownClient) {
                switch -CaseSensitive ($resource.address) {
                    'module.azure.azapi_resource.identity' {
                        $change.after_unknown = @{ id = $true; output = $true }
                    }
                    'module.azure.azapi_resource.identity_role_assignment' {
                        $change.after_unknown = @{ body = @{ properties = @{ principalId = $true } } }
                    }
                    'module.azure.azuread_group_member.example' {
                        $change.after_unknown = @{ member_object_id = $true }
                    }
                    default { $change.after_unknown = @{ parent_id = $true } }
                }
            }
        }
        $plan.planned_values.root_module.child_modules[0].resources += @{
            address = 'module.azure.data.azuread_group.entra_readers'
            mode = 'data'
            type = 'azuread_group'
            values = @{ display_name = 'grp-synthetic-directory-readers'; object_id = $groupId }
        }
        return $plan
    }

    function Read-AvmTestBamiSummary {
        param([object[]] $Information)

        $records = @($Information | Where-Object { $_.Tags -contains 'AvmBamiIdentityPlanSummary' })
        $records.Count | Should -Be 1
        $prefix = "BAMI candidate identity plan summary:`n"
        $records[0].MessageData.StartsWith($prefix) | Should -BeTrue
        return ConvertFrom-Json -InputObject $records[0].MessageData.Substring($prefix.Length) -AsHashtable -Depth 20
    }
}

Describe 'BAMI candidate plan summary' -Tag Component {
    BeforeEach {
        $script:previousEnvironment = @{}
        foreach ($name in @('GITHUB_ACTIONS', 'GITHUB_REPOSITORY', 'GITHUB_REPOSITORY_ID', 'GITHUB_REF', 'ARM_CLIENT_SECRET')) {
            $script:previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
        $env:GITHUB_REPOSITORY_ID = '9012'
        $env:GITHUB_REF = 'refs/heads/main'
        $env:ARM_CLIENT_SECRET = 'DO_NOT_LOG_ENV_CREDENTIAL'
        $script:repo = [pscustomobject]@{
            full_name = 'Azure/terraform-azurerm-avm-ptn-example-repo'
            name = 'terraform-azurerm-avm-ptn-example-repo'
            id = 1234
            fork = $false
            owner = [pscustomobject]@{ login = 'Azure'; id = 5678 }
            unselected = 'DO_NOT_LOG_REPOSITORY_METADATA'
        }
        $script:plan = New-AvmTestBamiSummaryPlan -KnownClient
        $script:processCalls = [System.Collections.Generic.List[object]]::new()
        $script:parameters = @{
            RepoId = 'avm-ptn-example-repo'
            Repository = $script:repo.full_name
            BamiValues = New-AvmTestBamiSettings
            Backend = @{
                TenantId = '30000000-0000-4000-8000-000000000001'
                SubscriptionId = '30000000-0000-4000-8000-000000000002'
                ClientId = '30000000-0000-4000-8000-000000000003'
                StorageAccountName = 'syntheticstate'
                ContainerName = 'synthetic-state'
            }
            Root = Join-Path $TestDrive 'candidate-root'
            TemporaryRoot = $TestDrive
            RepositorySyncRepositoryId = '9012'
        }
        Mock Invoke-RepositoryGitHubApi {
            if ($Endpoint -ceq 'repos/Azure/azure-verified-modules-tools') {
                [pscustomobject]@{
                    full_name = 'Azure/azure-verified-modules-tools'
                    id = 9012
                    fork = $false
                    owner = [pscustomobject]@{ login = 'Azure'; id = 5678 }
                }
            }
            elseif ($Endpoint -ceq "repos/$($script:repo.full_name)") { $script:repo }
            else { throw [System.InvalidOperationException]::new('Unexpected synthetic GitHub request.') }
        }
        Mock Invoke-RepositorySyncProcess {
            param($Command, $Arguments, $WorkingDirectory, $EnvVars, $TimeoutSec)

            $Command | Should -BeExactly 'terraform'
            $EnvVars.ARM_CLIENT_SECRET | Should -BeNullOrEmpty
            $script:processCalls.Add(@{ Arguments = $Arguments; WorkingDirectory = $WorkingDirectory })
            $stdout = 'DO_NOT_LOG_RAW_TERRAFORM_STDOUT'
            switch -CaseSensitive ($Arguments[0]) {
                'init' {}
                'plan' {
                    $path = @($Arguments | Where-Object { $_.StartsWith('-out=') })[0].Substring('-out='.Length)
                    [System.IO.File]::WriteAllText($path, 'DO_NOT_LOG_SYNTHETIC_PLAN_BINARY')
                }
                'show' {
                    Test-Path -LiteralPath $Arguments[-1] | Should -BeTrue
                    $stdout = ConvertTo-Json -InputObject $script:plan -Depth 40 -Compress
                }
                'apply' { Test-Path -LiteralPath $Arguments[-1] | Should -BeTrue }
                'output' {
                    $identity = New-AvmTestBamiIdentity
                    $identity.repository_owner_id = '5678'
                    $stdout = ConvertTo-Json -InputObject @{
                        test_identity = @{ value = $identity }
                        credential = @{ value = 'DO_NOT_LOG_APPLY_OUTPUT'; sensitive = $true }
                    } -Depth 10 -Compress
                }
                default { throw [System.InvalidOperationException]::new('Unexpected synthetic Terraform command.') }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = $stdout; StdErr = 'DO_NOT_LOG_TERRAFORM_STDERR' }
        }
    }

    AfterEach {
        foreach ($name in $script:previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:previousEnvironment[$name])
        }
        @(Get-ChildItem -LiteralPath $TestDrive -Directory | Where-Object Name -Like 'avm-bami-*').Count | Should -Be 0
    }

    It 'logs exactly the approved fields and real scopes without adding success-stream objects' {
        $script:plan.resource_changes[1].change.actions = @('update')
        $result = @(Invoke-AvmBamiRepositoryIdentity @script:parameters -InformationVariable information 6>$null)
        $result.Count | Should -Be 1
        ($result[0].PSObject.Properties.Name | Sort-Object) -join ',' | Should -BeExactly 'ConsumerSettings,StateKey,Status'
        $result[0].Status | Should -BeExactly 'Ready'
        $summary = Read-AvmTestBamiSummary -Information $information
        ($summary.Keys | Sort-Object) -join ',' |
            Should -BeExactly 'directory_readers_group,expected_tenant_id,repository,repository_id,repository_owner_id,resources'
        $summary.repository | Should -BeExactly $script:repo.full_name
        $summary.repository_id | Should -BeExactly '1234'
        $summary.repository_owner_id | Should -BeExactly '5678'
        $summary.expected_tenant_id | Should -BeExactly $script:parameters.BamiValues.TEST_BAMI_TENANT_ID
        $summary.directory_readers_group | Should -BeExactly 'grp-synthetic-directory-readers'
        $summary.resources.Count | Should -Be 7
        $planned = @($script:plan.planned_values.root_module.child_modules[0].resources | Where-Object { $_.mode -ceq 'managed' })
        ($summary.resources.address | Sort-Object) -join ',' | Should -BeExactly (($planned.address | Sort-Object) -join ',')
        foreach ($resource in $summary.resources) {
            $change = @($script:plan.resource_changes | Where-Object { $_.address -ceq $resource.address })[0]
            ($resource.actions -is [array]) | Should -BeTrue
            $resource.actions -join ',' | Should -BeExactly ($change.change.actions -join ',')
            $source = @($planned | Where-Object { $_.address -ceq $resource.address })[0].values
            $expectedFields = switch -CaseSensitive ($resource.address) {
                'module.azure.azapi_resource.identity' {
                    $resource.type | Should -BeExactly $source.type
                    $resource.parent_id | Should -BeExactly $source.parent_id
                    $resource.name | Should -BeExactly $source.name
                    $resource.id | Should -BeExactly $source.id
                    $resource.client_id | Should -BeExactly $source.output.properties.clientId
                    $resource.tenant_id | Should -BeExactly $source.output.properties.tenantId
                    $resource.principal_id | Should -BeExactly $source.output.properties.principalId
                    'actions,address,client_id,id,name,parent_id,principal_id,tenant_id,type'
                }
                'module.azure.azapi_resource.identity_role_assignment' {
                    $resource.type | Should -BeExactly $source.type
                    foreach ($field in @('roleDefinitionId', 'principalId', 'principalType', 'conditionVersion', 'condition')) {
                        $resource[$field] | Should -BeExactly $source.body.properties[$field]
                    }
                    $resource.parent_id | Should -BeExactly $source.parent_id
                    $resource.condition | Should -Match 'roleAssignments/write'
                    $resource.condition | Should -Match 'roleAssignments/delete'
                    'actions,address,condition,conditionVersion,parent_id,principalId,principalType,roleDefinitionId,type'
                }
                'module.azure.azuread_group_member.example' {
                    $resource.group_object_id | Should -BeExactly $source.group_object_id
                    $resource.member_object_id | Should -BeExactly $source.member_object_id
                    'actions,address,group_object_id,member_object_id'
                }
                default {
                    $resource.type | Should -BeExactly $source.type
                    $resource.name | Should -BeExactly $source.name
                    $resource.parent_id | Should -BeExactly $source.parent_id
                    $resource.issuer | Should -BeExactly $source.body.properties.issuer
                    $resource.subject | Should -BeExactly $source.body.properties.subject
                    ($resource.audiences -is [array]) | Should -BeTrue
                    $resource.audiences -join ',' | Should -BeExactly ($source.body.properties.audiences -join ',')
                    'actions,address,audiences,issuer,name,parent_id,subject,type'
                }
            }
            ($resource.Keys | Sort-Object) -join ',' | Should -BeExactly $expectedFields
        }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments[0] -in @('apply', 'output') }
    }

    It 'excludes sentinel secrets in unselected plan, state, output, resource, process and environment fields' {
        foreach ($field in @('variables', 'prior_state', 'configuration', 'output_changes', 'raw_plan')) {
            $script:plan[$field] = @{ credential = "DO_NOT_LOG_$field" }
        }
        $script:plan.planned_values.outputs.credential = @{ value = 'DO_NOT_LOG_PLANNED_OUTPUT'; sensitive = $true }
        foreach ($resource in $script:plan.planned_values.root_module.child_modules[0].resources) {
            $resource.values.unselected = @{ credential = 'DO_NOT_LOG_RESOURCE_VALUES' }
            if ($resource.values.Contains('body')) {
                $resource.values.body.unselected = 'DO_NOT_LOG_RESOURCE_BODY'
                $resource.values.body.properties.unselected = 'DO_NOT_LOG_RESOURCE_PROPERTIES'
            }
        }
        $script:plan.planned_values.root_module.child_modules[0].resources[0].values.output.properties.unselected = 'DO_NOT_LOG_IDENTITY_OUTPUT'
        foreach ($change in $script:plan.resource_changes) {
            $change.change.before = @{ credential = 'DO_NOT_LOG_BEFORE' }
            $change.change.after.unselected = 'DO_NOT_LOG_AFTER'
        }
        $script:plan.planned_values.root_module.child_modules[0].resources += @{
            address = 'data.synthetic.unselected'
            mode = 'data'
            values = @{ credential = 'DO_NOT_LOG_UNSELECTED_DATA' }
        }

        $records = @(Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false *>&1)

        ($records | Out-String -Width 4096) | Should -Not -Match 'DO_NOT_LOG'
        $information = @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $information.Count | Should -Be 1
        $result = @($records | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        $result.Count | Should -Be 1
        $result[0].Status | Should -BeExactly 'Ready'
        $summary = Read-AvmTestBamiSummary -Information $information
        $summary.resources.Count | Should -Be 7
        $summary.resources.address | Should -Not -Contain 'data.synthetic.unselected'
    }

    It 'marks apply-time unknown IDs without inventing values or changing the pending result' {
        $script:plan = New-AvmTestBamiSummaryPlan
        $result = @(Invoke-AvmBamiRepositoryIdentity @script:parameters -InformationVariable information 6>$null)
        $result.Count | Should -Be 1
        $result[0].Status | Should -BeExactly 'PendingCandidateIdentity'
        $result[0].ConsumerSettings | Should -BeNullOrEmpty
        $summary = Read-AvmTestBamiSummary -Information $information
        foreach ($field in @('id', 'client_id', 'tenant_id', 'principal_id')) {
            $summary.resources[0][$field] | Should -BeExactly '[unknown until apply]'
        }
        $summary.resources[1].principalId | Should -BeExactly '[unknown until apply]'
        $summary.resources[2].member_object_id | Should -BeExactly '[unknown until apply]'
        $summary.resources[2].group_object_id | Should -BeExactly '10000000-0000-4000-8000-000000000008'
        foreach ($credential in $summary.resources[3..6]) {
            $credential.parent_id | Should -BeExactly '[unknown until apply]'
            $credential.subject | Should -Not -Match '\[unknown'
        }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments[0] -in @('apply', 'output') }
    }

    It 'distinguishes absent fields and actions from explicit apply-time unknowns' {
        $script:plan.planned_values.root_module.child_modules[0].resources[0].values.Remove('id')
        $script:plan.resource_changes = @($script:plan.resource_changes | Where-Object { $_.address -cne 'module.azure.azapi_resource.identity' })
        $script:plan.planned_values.root_module.child_modules[0].resources = @(
            $script:plan.planned_values.root_module.child_modules[0].resources | Where-Object { $_.mode -ceq 'managed' }
        )
        $result = Invoke-AvmBamiRepositoryIdentity @script:parameters -InformationVariable information 6>$null
        $summary = Read-AvmTestBamiSummary -Information $information
        $result.Status | Should -BeExactly 'Ready'
        $summary.resources[0].id | Should -BeExactly '[not present in plan]'
        $summary.resources[0].actions | Should -BeExactly '[unavailable: missing or ambiguous actions]'
        $summary.directory_readers_group | Should -BeExactly '[not present in plan]'
    }

    It 'never serializes an unexpected object in an allow-listed scalar field' {
        $script:plan.planned_values.root_module.child_modules[0].resources[0].values.output.properties.clientId = @{
            credential = 'DO_NOT_LOG_UNEXPECTED_OBJECT'
        }
        $null = Invoke-AvmBamiRepositoryIdentity @script:parameters -InformationVariable information 6>$null
        $summary = Read-AvmTestBamiSummary -Information $information
        $summary.resources[0].client_id | Should -BeExactly '[unavailable: expected a string or string array]'
        $information.MessageData | Should -Not -Match 'DO_NOT_LOG'
    }

    It 'honors sensitive masks without printing selected secret values: <Mask>' -ForEach @(
        @{ Mask = 'planned ancestor' }
        @{ Mask = 'planned leaf' }
        @{ Mask = 'change ancestor' }
        @{ Mask = 'change leaf' }
        @{ Mask = 'sensitive and unknown' }
    ) {
        $resource = $script:plan.planned_values.root_module.child_modules[0].resources[0]
        $change = $script:plan.resource_changes[0].change
        $resource.values.output.properties.clientId = 'DO_NOT_LOG_SELECTED_SECRET'
        switch ($Mask) {
            'planned ancestor' { $resource.sensitive_values = @{ output = $true } }
            'planned leaf' { $resource.sensitive_values = @{ output = @{ properties = @{ clientId = $true } } } }
            'change ancestor' { $change.after_sensitive = $true }
            'change leaf' { $change.after_sensitive = @{ output = @{ properties = @{ clientId = $true } } } }
            'sensitive and unknown' {
                $change.after_sensitive = @{ output = $true }
                $change.after_unknown = @{ output = $true }
            }
        }
        $null = Invoke-AvmBamiRepositoryIdentity @script:parameters -InformationVariable information 6>$null
        $summary = Read-AvmTestBamiSummary -Information $information
        $summary.resources[0].client_id | Should -BeExactly '[redacted: sensitive]'
        $information.MessageData | Should -Not -Match 'DO_NOT_LOG'
    }

    It 'redacts an audience list with a sensitive element and escapes control characters in text' {
        $resource = $script:plan.planned_values.root_module.child_modules[0].resources[3]
        $resource.values.body.properties.audiences = @('DO_NOT_LOG_SENSITIVE_AUDIENCE')
        $resource.sensitive_values = @{ body = @{ properties = @{ audiences = @($true) } } }
        $script:plan.planned_values.root_module.child_modules[0].resources[-1].values.display_name = "synthetic`n::warning::not-an-annotation"
        $null = Invoke-AvmBamiRepositoryIdentity @script:parameters -InformationVariable information 6>$null
        $summary = Read-AvmTestBamiSummary -Information $information
        $summary.resources[3].audiences | Should -BeExactly '[redacted: sensitive]'
        $summary.directory_readers_group | Should -BeExactly "synthetic`n::warning::not-an-annotation"
        $information.MessageData | Should -Not -Match 'DO_NOT_LOG|(?m)^::warning::'
    }

    It 'keeps a known identity pending when its validation credential still needs applying' {
        $script:plan = New-AvmTestBamiSummaryPlan -KnownClient -ValidationPending
        $result = Invoke-AvmBamiRepositoryIdentity @script:parameters -InformationVariable information 6>$null
        $summary = Read-AvmTestBamiSummary -Information $information
        $result.Status | Should -BeExactly 'PendingCandidateIdentity'
        $summary.resources[6].actions -join ',' | Should -BeExactly 'create'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments[0] -in @('apply', 'output') }
    }

    It 'shows the regenerated apply plan and applies only that invocation saved binary' {
        $script:plan = New-AvmTestBamiSummaryPlan
        $preview = Invoke-AvmBamiRepositoryIdentity @script:parameters -InformationVariable previewInformation 6>$null
        $script:plan = New-AvmTestBamiSummaryPlan -KnownClient
        $script:plan.resource_changes[1].change.actions = @('update')
        $result = Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false -InformationVariable applyInformation 6>$null
        $previewSummary = Read-AvmTestBamiSummary -Information $previewInformation
        $applySummary = Read-AvmTestBamiSummary -Information $applyInformation
        $preview.Status | Should -BeExactly 'PendingCandidateIdentity'
        $result.Status | Should -BeExactly 'Ready'
        $result.ConsumerSettings.client_id | Should -BeExactly '10000000-0000-4000-8000-000000000006'
        $previewSummary.resources[0].id | Should -BeExactly '[unknown until apply]'
        $applySummary.resources[0].id | Should -BeExactly (New-AvmTestBamiIdentity).identity_resource_id
        $applySummary.resources[1].actions -join ',' | Should -BeExactly 'update'
        $planCalls = @($script:processCalls | Where-Object { $_.Arguments[0] -ceq 'plan' })
        $planCalls.Count | Should -Be 2
        $paths = @($planCalls | ForEach-Object {
                @($_.Arguments | Where-Object { $_.StartsWith('-out=') })[0].Substring('-out='.Length)
            })
        $paths[0] | Should -Not -Be $paths[1]
        $apply = @($script:processCalls | Where-Object { $_.Arguments[0] -ceq 'apply' })
        $apply.Count | Should -Be 1
        $apply[0].Arguments[-1] | Should -BeExactly $paths[1]
        $apply[0].Arguments | Should -Not -Contain '-auto-approve'
        ($script:processCalls | ForEach-Object { $_.Arguments[0] }) -join ',' |
            Should -BeExactly 'init,plan,show,init,plan,show,apply,output'
    }

    It 'fails invalid or mixed plans before logging any summary or applying: <Case>' -ForEach @(
        @{ Case = 'extra managed resource'; Mutate = { param($Plan) $Plan.planned_values.root_module.child_modules[0].resources += @{ address = 'module.azure.azapi_resource.unexpected'; mode = 'managed'; values = @{ credential = 'DO_NOT_LOG_INVALID' } } } }
        @{ Case = 'missing resource'; Mutate = { param($Plan) $Plan.planned_values.root_module.child_modules[0].resources = $Plan.planned_values.root_module.child_modules[0].resources[0..5] } }
        @{ Case = 'delete'; Mutate = { param($Plan) $Plan.resource_changes[2].change.actions = @('delete') } }
        @{ Case = 'replacement'; Mutate = { param($Plan) $Plan.resource_changes[2].change.actions = @('create', 'delete') } }
        @{ Case = 'identity scope'; Mutate = { param($Plan) $Plan.planned_values.root_module.child_modules[0].resources[0].values.parent_id = '/subscriptions/wrong/resourceGroups/wrong' } }
        @{ Case = 'management group'; Mutate = { param($Plan) $Plan.planned_values.root_module.child_modules[0].resources[1].values.parent_id = '/providers/Microsoft.Management/managementGroups/wrong' } }
        @{ Case = 'condition version'; Mutate = { param($Plan) $Plan.planned_values.root_module.child_modules[0].resources[1].values.body.properties.conditionVersion = '1.0' } }
        @{ Case = 'delegation deny'; Mutate = { param($Plan) $properties = $Plan.planned_values.root_module.child_modules[0].resources[1].values.body.properties; $properties.condition = $properties.condition.Replace('8e3af657-a8ff-443c-a75c-2fe8c4bcb635, ', '') } }
        @{ Case = 'validation trust'; Mutate = { param($Plan) $Plan.planned_values.root_module.child_modules[0].resources[6].values.body.properties.subject = 'repo:untrusted/repo:environment:avm-validation' } }
        @{ Case = 'errored plan'; Mutate = { param($Plan) $Plan.errored = $true } }
    ) {
        & $Mutate $script:plan
        Mock Write-AvmBamiIdentityPlanSummary { throw [System.InvalidOperationException]::new('Invalid plans must not reach the summary.') }
        { Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false } | Should -Throw
        Should -Invoke Write-AvmBamiIdentityPlanSummary -Exactly 0
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments[0] -in @('apply', 'output') }
    }

    It 'does not plan or log a summary under WhatIf' {
        Mock Write-AvmBamiIdentityPlanSummary {}
        $result = Invoke-AvmBamiRepositoryIdentity @script:parameters -WhatIf
        $result.Status | Should -BeExactly 'Preview'
        Should -Invoke Write-AvmBamiIdentityPlanSummary -Exactly 0
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }
}
