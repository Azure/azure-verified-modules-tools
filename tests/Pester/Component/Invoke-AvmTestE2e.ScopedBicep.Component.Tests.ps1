#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $script:subscription = '00000000-0000-0000-0000-000000000001'
    $script:tenant = '00000000-0000-0000-0000-000000000002'
    $script:managementGroup = 'test-management-group'
    $script:pinnedFixturePath = Join-Path $script:repoRoot `
        'tests\fixtures\bicep-scoped\role-definition-mg-default.6eb8e6ff.json'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep scoped end-to-end deployments' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ('scoped-bicep-' + [guid]::NewGuid().ToString('N'))
        $caseDirectory = Join-Path $script:root 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $caseDirectory -Force
        Set-Content -LiteralPath (Join-Path $script:root 'main.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        $script:source = Join-Path $caseDirectory 'main.test.bicep'
        Set-Content -LiteralPath $script:source -Value 'param name string' -Encoding utf8NoBOM

        $script:state = [pscustomobject]@{
            Scope                 = 'sub'
            Schema                = 'subscriptionDeploymentTemplate'
            ResourceType          = 'Microsoft.Authorization/policyDefinitions'
            Nested                = $false
            NestedMode            = 'Incremental'
            NestedProperty        = ''
            CompiledTemplateJson  = $null
            PreviewKind           = 'Create'
            PreviewIdOverride     = $null
            PreviewMissingAfter   = $false
            PreviewWrongGroupTag  = $false
            CredentialMismatch    = $false
            GroupMismatch         = $false
            ExistingDeployment    = $false
            ExistingResource      = $false
            FailedOperation       = ''
            FailedCreate          = $false
            CreateWithoutHistory  = $false
            BadOperationId        = $false
            ForeignOperationId    = $false
            OperationWasUpdate    = $false
            DeleteFails           = $false
            GroupDeleteFails      = $false
            ForeignGroupResources = @()
            AssertionFails        = $false
            PesterInput           = $null
            ResourceId            = ''
            ResourceName          = ''
            NestedName            = ''
            RunId                 = ''
            Groups                = @{}
            Resources             = @{}
            Deployments           = @{}
            Calls                 = [System.Collections.Generic.List[object]]::new()
        }
        InModuleScope 'Avm.Authoring' -Parameters @{
            State = $script:state; S = $script:subscription
            T = $script:tenant; M = $script:managementGroup
        } {
            param($State, $S, $T, $M)
            $script:scopedE2eState = $State
            $script:scopedE2eSubscription = $S
            $script:scopedE2eTenant = $T
            $script:scopedE2eManagementGroup = $M
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Path = 'fake-bicep'; Version = 'pinned'; Source = 'stub' }
            }
            Mock Get-Command {
                [pscustomobject]@{ Source = 'fake-az' }
            } -ParameterFilter { $Name -eq 'az' }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList, $TimeoutSec)
                $state = $script:scopedE2eState
                $state.Calls.Add([pscustomobject]@{
                        FilePath = $FilePath
                        Arguments = [string[]]$ArgumentList
                        TimeoutSec = $TimeoutSec
                    })
                if ($FilePath -eq 'fake-bicep') {
                    if ($null -ne $state.CompiledTemplateJson) {
                        return [pscustomobject]@{
                            ExitCode = 0; StdOut = $state.CompiledTemplateJson; StdErr = ''
                        }
                    }
                    $resource = @{
                        type = $state.ResourceType
                        name = '#_namePrefix_#-policy'
                    }
                    if ($state.ResourceType -eq 'Microsoft.Resources/resourceGroups') {
                        $resource.name = '#_namePrefix_#-group'
                        $resource.tags = @{ 'avm-e2e-run-id' = '#_avmE2eRunId_#' }
                    }
                    if ($state.Nested) {
                        $properties = @{
                            mode = $state.NestedMode
                            template = @{ resources = @($resource) }
                        }
                        if ($state.NestedProperty) {
                            $properties[$state.NestedProperty] = @{ type = 'LastSuccessful' }
                        }
                        $resource = @{
                            type = 'Microsoft.Resources/deployments'
                            name = 'nested-#_avmE2eSuffix_#'
                            properties = $properties
                        }
                    }
                    $template = @{
                        '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/$($state.Schema).json#"
                        resources = @($resource)
                    }
                    return [pscustomobject]@{
                        ExitCode = 0; StdOut = $template | ConvertTo-Json -Depth 16 -Compress; StdErr = ''
                    }
                }
                if ($FilePath -eq [System.Environment]::ProcessPath) {
                    $inputIndex = [array]::IndexOf($ArgumentList, '-InputPath')
                    $resultIndex = [array]::IndexOf($ArgumentList, '-ResultPath')
                    $state.PesterInput = Get-Content -LiteralPath $ArgumentList[$inputIndex + 1] `
                        -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                    $passed = if ($state.AssertionFails) { 0 } else { 1 }
                    $failed = if ($state.AssertionFails) { 1 } else { 0 }
                    $summary = @{
                        Version = '5.7.1'; Total = 1; Passed = $passed; Failed = $failed
                        Skipped = 0; Inconclusive = 0; Filtered = 0
                        Issues = if ($state.AssertionFails) {
                            @(@{
                                    File = $state.PesterInput.Files[0]; Line = 2; Column = 0
                                    Severity = 'error'; Code = 'avm.bicep.pester-failed'
                                    Message = 'Expected created definition.'
                                })
                        }
                        else { @() }
                    }
                    [System.IO.File]::WriteAllText(
                        $ArgumentList[$resultIndex + 1],
                        ($summary | ConvertTo-Json -Depth 8 -Compress),
                        [System.Text.UTF8Encoding]::new($false))
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                if ($FilePath -ne 'fake-az') {
                    throw "Unexpected fake executable: $FilePath"
                }
                if ($ArgumentList[0] -eq 'account' -and $ArgumentList[1] -eq 'show') {
                    $tenant = if ($state.CredentialMismatch) {
                        '00000000-0000-0000-0000-000000000003'
                    }
                    else { $script:scopedE2eTenant }
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = (@{
                                id = $script:scopedE2eSubscription
                                tenantId = $tenant; state = 'Enabled'
                            } | ConvertTo-Json -Compress)
                        StdErr = ''
                    }
                }
                if ($ArgumentList[0] -eq 'account' -and
                    $ArgumentList[1] -eq 'management-group') {
                    $groupId = if ($state.GroupMismatch) {
                        '/providers/Microsoft.Management/managementGroups/another-group'
                    }
                    else {
                        "/providers/Microsoft.Management/managementGroups/$script:scopedE2eManagementGroup"
                    }
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = (@{ id = $groupId; name = $script:scopedE2eManagementGroup } |
                            ConvertTo-Json -Compress)
                        StdErr = ''
                    }
                }
                $nameIndex = [array]::IndexOf($ArgumentList, '--name')
                $name = if ($nameIndex -ge 0) { $ArgumentList[$nameIndex + 1] } else { '' }
                if ($ArgumentList[0] -eq 'deployment') {
                    $command = if ($ArgumentList[1] -eq 'operation') {
                        $ArgumentList[3]
                    }
                    else { $ArgumentList[2] }
                    $prefix = switch ($state.Scope) {
                        'sub' { "/subscriptions/$script:scopedE2eSubscription/providers/" }
                        'mg' {
                            "/providers/Microsoft.Management/managementGroups/$script:scopedE2eManagementGroup/providers/"
                        }
                        'tenant' { '/providers/' }
                    }
                    $deploymentId = "${prefix}Microsoft.Resources/deployments/$name"
                    if ($command -eq 'show') {
                        if ($state.ExistingDeployment -and
                            -not $state.Deployments.ContainsKey($name)) {
                            $stored = @{
                                id = $deploymentId; name = $name
                                properties = @{ provisioningState = 'Succeeded' }
                            }
                        }
                        elseif ($state.Deployments.ContainsKey($name)) {
                            $stored = $state.Deployments[$name]
                        }
                        else {
                            return [pscustomobject]@{
                                ExitCode = 1; StdOut = ''; StdErr = '(DeploymentNotFound) not found'
                            }
                        }
                        return [pscustomobject]@{
                            ExitCode = 0; StdOut = $stored | ConvertTo-Json -Depth 10 -Compress; StdErr = ''
                        }
                    }
                    if ($command -eq 'list') {
                        if ($state.BadOperationId) {
                            $operationId = "${deploymentId}/operations/wrong/extra"
                        }
                        else {
                            $operationId = "${deploymentId}/operations/one"
                        }
                        $resourceId = if ($state.Nested -and $name -like 'avm-e2e-*') {
                            "${prefix}Microsoft.Resources/deployments/$($state.NestedName)"
                        }
                        elseif ($state.ForeignOperationId) {
                            "${prefix}Microsoft.Authorization/roleAssignments/foreign"
                        }
                        else { $state.ResourceId }
                        $type = if ($state.Nested -and $name -like 'avm-e2e-*') {
                            'Microsoft.Resources/deployments'
                        }
                        elseif ($state.ForeignOperationId) {
                            'Microsoft.Authorization/roleAssignments'
                        }
                        else { $state.ResourceType }
                        $operation = @{
                            id = $operationId; operationId = 'one'
                            properties = @{
                                provisioningOperation = if ($state.OperationWasUpdate) {
                                    'Update'
                                }
                                else { 'Create' }
                                provisioningState = 'Succeeded'
                                targetResource = @{
                                    id = $resourceId; resourceType = $type
                                    resourceName = $state.ResourceName
                                }
                            }
                        }
                        return [pscustomobject]@{
                            ExitCode = 0
                            StdOut = ConvertTo-Json -InputObject @($operation) -Depth 12 -Compress
                            StdErr = ''
                        }
                    }
                    $templateIndex = [array]::IndexOf($ArgumentList, '--template-file')
                    $template = Get-Content -LiteralPath $ArgumentList[$templateIndex + 1] `
                        -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                    $resource = if ($state.Nested) {
                        $template.resources[0].properties.template.resources[0]
                    }
                    else { $template.resources[0] }
                    $state.ResourceName = [string]$resource.name
                    $state.NestedName = if ($state.Nested) {
                        [string]$template.resources[0].name
                    }
                    else { '' }
                    $state.RunId = $name.Substring('avm-e2e-'.Length)
                    $state.ResourceId = switch ($state.Scope) {
                        'sub' {
                            if ($state.ResourceType -eq 'Microsoft.Resources/resourceGroups') {
                                "/subscriptions/$script:scopedE2eSubscription/resourceGroups/$($state.ResourceName)"
                            }
                            else {
                                "/subscriptions/$script:scopedE2eSubscription/providers/$($state.ResourceType)/$($state.ResourceName)"
                            }
                        }
                        'mg' {
                            "/providers/Microsoft.Management/managementGroups/$script:scopedE2eManagementGroup/providers/$($state.ResourceType)/$($state.ResourceName)"
                        }
                        'tenant' { "/providers/$($state.ResourceType)/$($state.ResourceName)" }
                    }
                    if ($state.FailedOperation -eq $command) {
                        return [pscustomobject]@{
                            ExitCode = 1; StdOut = ''; StdErr = 'Fake authorization or ARM error'
                        }
                    }
                    if ($command -eq 'validate') {
                        return [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
                    }
                    if ($command -eq 'what-if') {
                        $id = if ($null -ne $state.PreviewIdOverride) {
                            $state.PreviewIdOverride
                        }
                        else { $state.ResourceId }
                        $after = if ($state.PreviewMissingAfter) { $null } else {
                            @{ name = $state.ResourceName; type = $state.ResourceType }
                        }
                        if ($state.ResourceType -eq 'Microsoft.Resources/resourceGroups' -and
                            $null -ne $after) {
                            $after.tags = @{
                                'avm-e2e-run-id' = if ($state.PreviewWrongGroupTag) {
                                    'another-run'
                                }
                                else { $state.RunId }
                            }
                        }
                        $previewChanges = @(@{
                                resourceId = $id; changeType = $state.PreviewKind; after = $after
                            })
                        if ($state.Nested) {
                            $previewChanges = @(
                                @{
                                    resourceId = "${prefix}Microsoft.Resources/deployments/$($state.NestedName)"
                                    changeType = 'Create'
                                    after = @{
                                        name = $state.NestedName
                                        type = 'Microsoft.Resources/deployments'
                                    }
                                }
                                $previewChanges[0]
                            )
                        }
                        return [pscustomobject]@{
                            ExitCode = 0
                            StdOut = @{ changes = $previewChanges } | ConvertTo-Json -Depth 12 -Compress
                            StdErr = ''
                        }
                    }
                    if ($command -eq 'create') {
                        if (-not $state.CreateWithoutHistory) {
                            $stored = @{
                                id = $deploymentId; name = $name
                                properties = @{
                                    provisioningState = if ($state.FailedCreate) { 'Failed' } else { 'Succeeded' }
                                    outputs = @{ result = @{ type = 'String'; value = 'created' } }
                                }
                            }
                            $state.Deployments[$name] = $stored
                            if ($state.Nested) {
                                $nestedName = $state.NestedName
                                $state.Deployments[$nestedName] = @{
                                    id = "${prefix}Microsoft.Resources/deployments/$nestedName"
                                    name = $nestedName
                                    properties = @{ provisioningState = 'Succeeded' }
                                }
                            }
                        }
                        if ($state.ResourceType -eq 'Microsoft.Resources/resourceGroups') {
                            $state.Groups[$state.ResourceName] = @{
                                id = $state.ResourceId; name = $state.ResourceName
                                type = $state.ResourceType
                                tags = @{ 'avm-e2e-run-id' = $state.RunId }
                            }
                        }
                        else {
                            $state.Resources[$state.ResourceId] = @{
                                id = $state.ResourceId; name = $state.ResourceName
                                type = $state.ResourceType
                            }
                        }
                        if ($state.FailedCreate -or $state.CreateWithoutHistory) {
                            return [pscustomobject]@{
                                ExitCode = 1; StdOut = ''; StdErr = 'Fake partial deployment failure'
                            }
                        }
                        return [pscustomobject]@{
                            ExitCode = 0; StdOut = $stored | ConvertTo-Json -Depth 10 -Compress; StdErr = ''
                        }
                    }
                }
                if ($ArgumentList[0] -eq 'resource') {
                    switch ($ArgumentList[1]) {
                        'show' {
                            $idIndex = [array]::IndexOf($ArgumentList, '--ids')
                            $id = $ArgumentList[$idIndex + 1]
                            if ($state.ExistingResource -and
                                -not $state.Resources.ContainsKey($id)) {
                                $found = @{
                                    id = $id; name = $state.ResourceName
                                    type = $state.ResourceType
                                }
                            }
                            elseif ($state.Resources.ContainsKey($id)) {
                                $found = $state.Resources[$id]
                            }
                            else {
                                return [pscustomobject]@{
                                    ExitCode = 1; StdOut = ''; StdErr = '(ResourceNotFound) not found'
                                }
                            }
                            return [pscustomobject]@{
                                ExitCode = 0; StdOut = $found | ConvertTo-Json -Depth 8 -Compress; StdErr = ''
                            }
                        }
                        'delete' {
                            if ($state.DeleteFails) {
                                return [pscustomobject]@{
                                    ExitCode = 1; StdOut = ''; StdErr = 'Fake deletion failure'
                                }
                            }
                            $idIndex = [array]::IndexOf($ArgumentList, '--ids')
                            $null = $state.Resources.Remove($ArgumentList[$idIndex + 1])
                            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                        }
                        'list' {
                            return [pscustomobject]@{
                                ExitCode = 0
                                StdOut = ConvertTo-Json -InputObject @($state.ForeignGroupResources) `
                                    -Depth 8 -Compress
                                StdErr = ''
                            }
                        }
                    }
                }
                if ($ArgumentList[0] -eq 'group') {
                    $groupName = $ArgumentList[$nameIndex + 1]
                    switch ($ArgumentList[1]) {
                        'exists' {
                            $exists = $state.Groups.ContainsKey($groupName)
                            return [pscustomobject]@{
                                ExitCode = 0; StdOut = $exists.ToString().ToLowerInvariant(); StdErr = ''
                            }
                        }
                        'show' {
                            $group = $state.Groups[$groupName]
                            if ($state.GroupMismatch) {
                                $group = @{
                                    id = $group.id; name = $group.name; type = $group.type
                                    tags = @{ 'avm-e2e-run-id' = 'another-run' }
                                }
                            }
                            return [pscustomobject]@{
                                ExitCode = 0; StdOut = $group | ConvertTo-Json -Depth 8 -Compress; StdErr = ''
                            }
                        }
                        'delete' {
                            if ($state.GroupDeleteFails) {
                                return [pscustomobject]@{
                                    ExitCode = 1; StdOut = ''; StdErr = 'Fake deletion failure'
                                }
                            }
                            $null = $state.Groups.Remove($groupName)
                            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                        }
                    }
                }
                throw "Unexpected fake Azure CLI call: $($ArgumentList -join ' ')"
            }
        }
    }

    It 'deploys and cleans an owned <Scope> definition using scoped operations' -ForEach @(
        @{ Scope = 'sub'; Schema = 'subscriptionDeploymentTemplate' }
        @{ Scope = 'mg'; Schema = 'managementGroupDeploymentTemplate' }
        @{ Scope = 'tenant'; Schema = 'tenantDeploymentTemplate' }
    ) {
        $script:state.Scope = $Scope
        $script:state.Schema = $Schema
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -ManagementGroupId $script:managementGroup -Location 'westus' `
            -SkipModuleVersionCheck

        $result.Status | Should -Be 'pass'
        $result.RunsTotal | Should -Be 1
        $result.RunsPassed | Should -Be 1
        $result.RunsFailed | Should -Be 0
        $result.CleanupPending.Count | Should -Be 0
        $result.WhatIfChanges.Count | Should -Be 1
        $result.AssertionResults[0].Status | Should -Be 'not-present'
        $script:state.ResourceName | Should -Match '^avm[0-9a-f]{10}-policy$'
        $script:state.Resources.Count | Should -Be 0
        $script:state.Deployments.Count | Should -Be 1
        $preview = $script:state.Calls |
            Where-Object { $_.Arguments[0] -eq 'deployment' -and
                $_.Arguments[2] -eq 'what-if' } | Select-Object -First 1
        $preview.Arguments | Should -Contain '--result-format'
        $preview.Arguments | Should -Contain 'FullResourcePayloads'
        $preview.Arguments | Should -Contain '--no-pretty-print'
        $removed = $script:state.Calls |
            Where-Object { $_.Arguments[0] -eq 'resource' -and
                $_.Arguments[1] -eq 'delete' } | Select-Object -First 1
        $removed.Arguments | Should -Contain $script:state.ResourceId
        $operations = $script:state.Calls |
            Where-Object { $_.Arguments[0] -eq 'deployment' -and
                $_.Arguments[1] -eq 'operation' } | Select-Object -First 1
        $operations.Arguments[2] | Should -Be $Scope
        if ($Scope -eq 'mg') {
            $operations.Arguments | Should -Contain $script:managementGroup
            @($script:state.Calls | Where-Object {
                    $_.Arguments[0] -eq 'account' -and
                    $_.Arguments[1] -eq 'management-group'
                }).Count | Should -BeGreaterThan 0
        }
    }

    It 'keeps a supplied run-specific name prefix instead of silently replacing it' {
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -Location 'westus' -Tokens @{ namePrefix = 'team#_avmE2eSuffix_#' } `
            -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $script:state.ResourceName | Should -Match '^team[0-9a-f]{10}-policy$'
    }

    It 'runs authored assertions after deployment and deletes on assertion failure' {
        $testPath = Join-Path (Split-Path -Parent $script:source) 'deployed.Tests.ps1'
        Set-Content -LiteralPath $testPath -Value "Describe 'deployed' { It 'fails' { } }" `
            -Encoding utf8NoBOM
        $script:state.AssertionFails = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -Location 'westus' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.RunsFailed | Should -Be 1
        $result.AssertionResults[0].Status | Should -Be 'fail'
        $script:state.PesterInput.TestInputData.DeploymentOutputs.result.value |
            Should -Be 'created'
        $script:state.Resources.Count | Should -Be 0
        $sequence = @($script:state.Calls | ForEach-Object {
                if ($_.FilePath -eq [System.Environment]::ProcessPath) { 'pester' }
                elseif ($_.Arguments[0] -eq 'resource' -and $_.Arguments[1] -eq 'delete') { 'delete' }
                elseif ($_.Arguments[0] -eq 'deployment') { $_.Arguments[2] }
                else { $_.Arguments[0] }
            })
        [array]::IndexOf($sequence, 'create') |
            Should -BeLessThan ([array]::IndexOf($sequence, 'pester'))
        [array]::IndexOf($sequence, 'pester') |
            Should -BeLessThan ([array]::IndexOf($sequence, 'delete'))
    }

    It 'discovers owned resources and removes them after partial ARM failure' {
        $script:state.FailedCreate = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -Location 'westus' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-deployment-failed'
        $result.CleanupPending.Count | Should -Be 0
        $script:state.Resources.Count | Should -Be 0
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment' -and
                $_.Arguments[1] -eq 'operation'
            }).Count | Should -Be 1
    }

    It 'refuses deployment if the selected account or management group is not verified' -ForEach @(
        @{ Case = 'wrong-tenant'; Scope = 'sub'; Schema = 'subscriptionDeploymentTemplate'; Field = 'CredentialMismatch' }
        @{ Case = 'wrong-group'; Scope = 'mg'; Schema = 'managementGroupDeploymentTemplate'; Field = 'GroupMismatch' }
    ) {
        $script:state.Scope = $Scope
        $script:state.Schema = $Schema
        $script:state.$Field = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -ManagementGroupId $script:managementGroup -Location 'westus' `
            -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-preflight-unsafe'
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment' -and $_.Arguments[2] -eq 'create'
            }).Count | Should -Be 0
    }

    It 'refuses an existing resource, deployment or unqualified prefix before Create' -ForEach @(
        @{ Case = 'existing-resource'; Field = 'ExistingResource'; Prefix = ''; Code = 'preflight-unsafe' }
        @{ Case = 'existing-deployment'; Field = 'ExistingDeployment'; Prefix = ''; Code = 'preflight-unsafe' }
        @{ Case = 'static-name'; Field = ''; Prefix = 'static'; Code = 'what-if-unsafe' }
    ) {
        if ($Field) { $script:state.$Field = $true }
        $input = @{
            Path = $script:root; SubscriptionId = $script:subscription
            TenantId = $script:tenant; Location = 'westus'; SkipModuleVersionCheck = $true
        }
        if ($Prefix) { $input.Tokens = @{ namePrefix = $Prefix } }
        $result = Invoke-AvmTestE2e @input
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be "avm.bicep.e2e-$Code"
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment' -and $_.Arguments[2] -eq 'create'
            }).Count | Should -Be 0
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'resource' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 0
    }

    It 'refuses incomplete what-if results and never invokes Create' -ForEach @(
        @{ Kind = 'Ignore'; PreviewKind = 'Ignore'; MissingAfter = $false; Code = 'what-if-unsafe' }
        @{ Kind = 'Deploy'; PreviewKind = 'Deploy'; MissingAfter = $false; Code = 'what-if-unsafe' }
        @{ Kind = 'NoChange'; PreviewKind = 'NoChange'; MissingAfter = $false; Code = 'what-if-unsafe' }
        @{ Kind = 'Modify'; PreviewKind = 'Modify'; MissingAfter = $false; Code = 'what-if-unsafe' }
        @{ Kind = 'unexpanded'; PreviewKind = 'Create'; MissingAfter = $true; Code = 'what-if-unsafe' }
    ) {
        $script:state.PreviewKind = $PreviewKind
        $script:state.PreviewMissingAfter = $MissingAfter
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -Location 'westus' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be "avm.bicep.e2e-$Code"
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment' -and $_.Arguments[2] -eq 'create'
            }).Count | Should -Be 0
    }

    It 'fails closed if deployment history or its operation IDs are untrustworthy' -ForEach @(
        @{ Kind = 'missing-history'; Field = 'CreateWithoutHistory' }
        @{ Kind = 'invalid-operation'; Field = 'BadOperationId' }
        @{ Kind = 'foreign-operation'; Field = 'ForeignOperationId' }
        @{ Kind = 'update-after-preview'; Field = 'OperationWasUpdate' }
    ) {
        $script:state.$Field = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -Location 'westus' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.RunsPassed | Should -Be 0
        $result.RunsFailed | Should -Be 1
        $result.CleanupPending | Should -Contain $script:state.ResourceId
        if ($Field -eq 'ForeignOperationId') {
            $result.CleanupPending | Should -Contain (
                "/subscriptions/$script:subscription/providers/Microsoft.Authorization/roleAssignments/foreign")
        }
        $result.Issues[-1].Code | Should -Be 'avm.bicep.e2e-cleanup-failed'
        $script:state.Resources.Count | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'resource' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 0
    }

    It 'reports cleanup pending and stops before the next case on deletion failure' {
        $second = Join-Path $script:root 'tests' 'e2e' 'second'
        $null = New-Item -ItemType Directory -Path $second -Force
        Set-Content -LiteralPath (Join-Path $second 'main.test.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        $script:state.DeleteFails = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -Location 'westus' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.RunsTotal | Should -Be 1
        $result.RunsFailed | Should -Be 1
        $result.RunsSkipped | Should -Be 1
        $result.CleanupPending.Count | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment' -and $_.Arguments[2] -eq 'create'
            }).Count | Should -Be 1
    }

    It 'deletes only an empty, run-tagged group created by a subscription example' {
        $script:state.ResourceType = 'Microsoft.Resources/resourceGroups'
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -Location 'westus' -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $script:state.Groups.Count | Should -Be 0
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'resource' -and $_.Arguments[1] -eq 'list'
            }).Count | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 1
    }

    It 'never deletes a tagged group containing untracked resources' {
        $script:state.ResourceType = 'Microsoft.Resources/resourceGroups'
        $script:state.ForeignGroupResources = @(@{
                id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/foreign/providers/Microsoft.Storage/storageAccounts/external'
            })
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -Location 'westus' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.CleanupPending | Should -Contain $script:state.ResourceId
        $result.CleanupPending | Should -Contain $script:state.ForeignGroupResources[0].id
        $script:state.Groups.Count | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 0
    }

    It 'checks ownership after a nested same-scope deployment before deleting its resources' {
        $script:state.Nested = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -Location 'westus' -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $result.WhatIfChanges.Count | Should -Be 2
        $script:state.Resources.Count | Should -Be 0
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment' -and
                $_.Arguments[1] -eq 'operation'
            }).Count | Should -Be 2
    }

    It 'preflights pinned symbolic resources and telemetry before mocked ARM validation' {
        $script:state.Scope = 'mg'
        $script:state.CompiledTemplateJson = Get-Content -LiteralPath $script:pinnedFixturePath `
            -Raw -Encoding utf8
        $script:state.FailedOperation = 'validate'
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -ManagementGroupId $script:managementGroup -Location 'westus' `
            -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-validate-failed'
        @($script:state.Calls | Where-Object {
                $_.FilePath -eq 'fake-az' -and
                $_.Arguments[0] -eq 'deployment' -and
                $_.Arguments[2] -eq 'validate'
            }).Count | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment' -and
                $_.Arguments[2] -eq 'create'
            }).Count | Should -Be 0
    }

    It 'refuses unsafe pinned symbolic <Case> before any Azure call' -ForEach @(
        @{ Case = 'assignment'; Mutation = 'type' }
        @{ Case = 'cross-scope write'; Mutation = 'scope' }
        @{ Case = 'unreviewed telemetry output'; Mutation = 'output' }
    ) {
        $script:state.Scope = 'mg'
        $template = Get-Content -LiteralPath $script:pinnedFixturePath -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable
        $symbolic = $template.resources[0].properties.template.resources
        switch ($Mutation) {
            type { $symbolic.res_roleDefinition_mg.type = 'Microsoft.Authorization/roleAssignments' }
            scope { $symbolic.res_roleDefinition_mg.scope = '[tenant()]' }
            output {
                $symbolic.avmTelemetry.properties.template.outputs.telemetry.value =
                    '[reference(''outside'')]'
            }
        }
        $script:state.CompiledTemplateJson = $template | ConvertTo-Json -Depth 100 -Compress
        { Invoke-AvmTestE2e -Path $script:root `
                -SubscriptionId $script:subscription -TenantId $script:tenant `
                -ManagementGroupId $script:managementGroup -Location 'westus' `
                -SkipModuleVersionCheck } | Should -Throw
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count |
            Should -Be 0
    }

    It 'refuses unsafe nested <Case> before any Azure call' -ForEach @(
        @{ Case = 'Complete mode'; Mode = 'Complete'; Property = '' }
        @{ Case = 'dynamic mode'; Mode = '[parameters(''mode'')]'; Property = '' }
        @{ Case = 'array mode'; Mode = @('Incremental'); Property = '' }
        @{ Case = 'rollback'; Mode = 'Incremental'; Property = 'onErrorDeployment' }
        @{ Case = 'linked parameters'; Mode = 'Incremental'; Property = 'parametersLink' }
    ) {
        $script:state.Nested = $true
        $script:state.NestedMode = $Mode
        $script:state.NestedProperty = $Property
        { Invoke-AvmTestE2e -Path $script:root `
                -SubscriptionId $script:subscription -TenantId $script:tenant `
                -Location 'westus' -SkipModuleVersionCheck } | Should -Throw
        @($script:state.Calls | Where-Object {
                $_.FilePath -eq 'fake-az'
            }).Count | Should -Be 0
    }

    It 'does not assume tenant-root access when ARM validation is denied' {
        $script:state.Scope = 'tenant'
        $script:state.Schema = 'tenantDeploymentTemplate'
        $script:state.FailedOperation = 'validate'
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -TenantId $script:tenant `
            -Location 'westus' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-validate-failed'
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment' -and $_.Arguments[2] -eq 'create'
            }).Count | Should -Be 0
    }
}
