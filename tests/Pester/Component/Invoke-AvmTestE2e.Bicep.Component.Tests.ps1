#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $script:subscription = '00000000-0000-0000-0000-000000000001'
    $script:groupSchema = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep isolated end-to-end deployments' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ('bicep-e2e-' + [guid]::NewGuid().ToString('N'))
        $caseDir = Join-Path $script:root 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $caseDir -Force
        Set-Content -LiteralPath (Join-Path $script:root 'main.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        $script:sourcePath = Join-Path $caseDir 'main.test.bicep'
        Set-Content -LiteralPath $script:sourcePath `
            -Value "param namePrefix string = 'demo'" -Encoding utf8NoBOM

        $script:state = [pscustomobject]@{
            Schema              = $script:groupSchema
            Resources           = @(@{ type = 'Microsoft.Storage/storageAccounts'; name = 'demo' })
            Groups              = @{}
            Calls               = [System.Collections.Generic.List[object]]::new()
            GroupExistsOutput   = $null
            CreateExit          = 0
            CreateOutput        = $null
            ShowExit            = 0
            ShowMismatch        = $false
            DeleteExit          = 0
            DeletePersists      = $false
            FailOperation       = ''
            WhatIfOutput        = $null
            WhatIfType          = 'Create'
            DeploymentState     = 'Succeeded'
            DeploymentOutput    = $null
            ResourceIdOverride  = $null
            CompiledJson        = ''
            TemporaryFile       = ''
            ParameterJson       = ''
            ParameterPath       = ''
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ State = $script:state; S = $script:subscription } {
            param($State, $S)
            $script:bicepE2eState = $State
            $script:bicepE2eSubscription = $S
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Path = 'fake-bicep'; Version = 'pinned'; Source = 'stub' }
            }
            Mock Get-Command {
                [pscustomobject]@{ Source = 'fake-az' }
            } -ParameterFilter { $Name -eq 'az' }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $script:bicepE2eState.Calls.Add([pscustomobject]@{
                        FilePath  = $FilePath
                        Arguments = [string[]]$ArgumentList
                    })
                if ($FilePath -eq 'fake-bicep') {
                    $template = @{
                        '$schema' = $script:bicepE2eState.Schema
                        resources = $script:bicepE2eState.Resources
                    }
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = $template | ConvertTo-Json -Depth 20 -Compress
                        StdErr   = ''
                    }
                }
                $nameIndex = [array]::IndexOf($ArgumentList, '--name')
                $name = if ($nameIndex -ge 0) { $ArgumentList[$nameIndex + 1] } else { '' }
                if ($ArgumentList[0] -eq 'group') {
                    switch ($ArgumentList[1]) {
                        'exists' {
                            $answer = if ($null -ne $script:bicepE2eState.GroupExistsOutput) {
                                $script:bicepE2eState.GroupExistsOutput
                            }
                            else {
                                $script:bicepE2eState.Groups.ContainsKey($name).ToString().ToLowerInvariant()
                            }
                            return [pscustomobject]@{ ExitCode = 0; StdOut = $answer; StdErr = '' }
                        }
                        'create' {
                            $tagIndex = [array]::IndexOf($ArgumentList, '--tags')
                            $runId = $ArgumentList[$tagIndex + 1].Substring('avm-e2e-run-id='.Length)
                            $group = @{
                                id   = "/subscriptions/$script:bicepE2eSubscription/resourceGroups/$name"
                                name = $name
                                tags = @{ 'avm-e2e-run-id' = $runId }
                            }
                            $script:bicepE2eState.Groups[$name] = $group
                            if ($script:bicepE2eState.CreateExit -ne 0) {
                                return [pscustomobject]@{
                                    ExitCode = 1; StdOut = ''; StdErr = 'Fake resource group creation failure'
                                }
                            }
                            $output = if ($null -ne $script:bicepE2eState.CreateOutput) {
                                $script:bicepE2eState.CreateOutput
                            }
                            else { $group | ConvertTo-Json -Depth 8 -Compress }
                            return [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' }
                        }
                        'show' {
                            if ($script:bicepE2eState.ShowExit -ne 0) {
                                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Show failed' }
                            }
                            $group = $script:bicepE2eState.Groups[$name]
                            if ($script:bicepE2eState.ShowMismatch) {
                                $group = @{
                                    id   = $group.id
                                    name = $group.name
                                    tags = @{ 'avm-e2e-run-id' = 'different-owner' }
                                }
                            }
                            return [pscustomobject]@{
                                ExitCode = 0; StdOut = $group | ConvertTo-Json -Depth 8 -Compress; StdErr = ''
                            }
                        }
                        'delete' {
                            if ($script:bicepE2eState.DeleteExit -ne 0) {
                                return [pscustomobject]@{
                                    ExitCode = 1; StdOut = ''; StdErr = 'Fake group deletion failure'
                                }
                            }
                            if (-not $script:bicepE2eState.DeletePersists) {
                                $null = $script:bicepE2eState.Groups.Remove($name)
                            }
                            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                        }
                    }
                }
                if ($ArgumentList[0] -eq 'deployment') {
                    $templateIndex = [array]::IndexOf($ArgumentList, '--template-file')
                    $script:bicepE2eState.TemporaryFile = $ArgumentList[$templateIndex + 1]
                    $script:bicepE2eState.CompiledJson = Get-Content `
                        -LiteralPath $script:bicepE2eState.TemporaryFile -Raw -Encoding utf8
                    $parameterIndex = [array]::IndexOf($ArgumentList, '--parameters')
                    if ($parameterIndex -ge 0) {
                        $script:bicepE2eState.ParameterPath = $ArgumentList[$parameterIndex + 1].Substring(1)
                        $script:bicepE2eState.ParameterJson = Get-Content `
                            -LiteralPath $script:bicepE2eState.ParameterPath -Raw -Encoding utf8
                    }
                    if ($script:bicepE2eState.FailOperation -eq $ArgumentList[2]) {
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Fake ARM failure' }
                    }
                    $groupIndex = [array]::IndexOf($ArgumentList, '--resource-group')
                    $groupName = $ArgumentList[$groupIndex + 1]
                    $resourceId = if ($null -ne $script:bicepE2eState.ResourceIdOverride) {
                        $script:bicepE2eState.ResourceIdOverride
                    }
                    else {
                        "/subscriptions/$script:bicepE2eSubscription/resourceGroups/$groupName/providers/Microsoft.Storage/storageAccounts/demo"
                    }
                    $preview = if ($null -ne $script:bicepE2eState.WhatIfOutput) {
                        $script:bicepE2eState.WhatIfOutput
                    }
                    else {
                        @{ changes = @(@{ resourceId = $resourceId; changeType = $script:bicepE2eState.WhatIfType }) } |
                            ConvertTo-Json -Depth 8 -Compress
                    }
                    $deploymentNameIndex = [array]::IndexOf($ArgumentList, '--name')
                    $deploymentName = $ArgumentList[$deploymentNameIndex + 1]
                    $deployment = @{
                        id = "/subscriptions/$script:bicepE2eSubscription/resourceGroups/$groupName/providers/Microsoft.Resources/deployments/$deploymentName"
                        name = $deploymentName
                        properties = @{ provisioningState = $script:bicepE2eState.DeploymentState }
                    } | ConvertTo-Json -Depth 8 -Compress
                    $output = if ($ArgumentList[2] -eq 'what-if') {
                        $preview
                    }
                    elseif ($ArgumentList[2] -eq 'create' -and
                        $null -ne $script:bicepE2eState.DeploymentOutput) {
                        $script:bicepE2eState.DeploymentOutput
                    }
                    else { $deployment }
                    return [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' }
                }
                throw "Unexpected fake subprocess: $FilePath $($ArgumentList -join ' ')"
            }
        }
    }

    It 'previews, deploys and deletes one group, without changing source or exposing parameters in argv' {
        $script:state.Resources[0].name = '#_namePrefix_#'
        Set-Content -LiteralPath $script:sourcePath `
            -Value "param namePrefix string = '#_namePrefix_#'" -Encoding utf8NoBOM
        $original = Get-Content -LiteralPath $script:sourcePath -Raw
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -Tokens @{ namePrefix = 'quote"slash\name' } `
            -Parameters @{ administrator = 'private-value' } -SkipModuleVersionCheck

        $result.Status | Should -Be 'pass'
        $result.RunsTotal | Should -Be 1
        $result.RunsPassed | Should -Be 1
        $result.RunsFailed | Should -Be 0
        $result.CleanupPending.Count | Should -Be 0
        $result.WhatIfChanges.Count | Should -Be 1
        $script:state.Groups.Count | Should -Be 0
        ($script:state.CompiledJson | ConvertFrom-Json -AsHashtable).resources[0].name |
            Should -Be 'quote"slash\name'
        ($script:state.ParameterJson | ConvertFrom-Json -AsHashtable).parameters.administrator.value |
            Should -Be 'private-value'
        (Get-Content -LiteralPath $script:sourcePath -Raw) | Should -BeExactly $original
        (Test-Path -LiteralPath $script:state.TemporaryFile) | Should -BeFalse
        (Test-Path -LiteralPath $script:state.ParameterPath) | Should -BeFalse
        $sequence = @($script:state.Calls | ForEach-Object {
                if ($_.FilePath -eq 'fake-bicep') { 'build' }
                elseif ($_.Arguments[0] -eq 'group') { 'group-' + $_.Arguments[1] }
                else { $_.Arguments[2] }
            })
        $sequence | Should -Be @('build', 'group-exists', 'group-create', 'validate',
            'what-if', 'create', 'group-exists', 'group-show', 'group-delete', 'group-exists')
        $create = $script:state.Calls |
            Where-Object { $_.Arguments[0] -eq 'deployment' -and $_.Arguments[2] -eq 'create' } |
            Select-Object -First 1
        $create.Arguments | Should -Contain '--mode'
        $create.Arguments | Should -Contain 'Incremental'
        $create.Arguments | Should -Contain $script:subscription
        $create.Arguments | Should -Not -Contain 'private-value'
    }

    It 'lists runnable paths without tools, credentials or version lookup' {
        InModuleScope 'Avm.Authoring' {
            Mock Resolve-AvmTool { throw 'List must not resolve tools' }
            Mock Test-AvmModuleVersion { throw 'List must not query PowerShell Gallery' }
        }
        (Invoke-AvmTestE2e -Path $script:root -List) |
            Should -Be '["tests/e2e/defaults"]'
        $script:state.Calls.Count | Should -Be 0

        Set-Content -LiteralPath (Join-Path (Split-Path $script:sourcePath) '.e2eignore') `
            -Value 'not yet released' -Encoding utf8NoBOM
        (Invoke-AvmTestE2e -Path $script:root -List) | Should -Be '[]'
        $script:state.Calls.Count | Should -Be 0
    }

    It 'skips ignored cases and rejects explicitly selected ignored cases' {
        Set-Content -LiteralPath (Join-Path (Split-Path $script:sourcePath) '.e2eignore') `
            -Value 'not yet released' -Encoding utf8NoBOM
        $skipped = Invoke-AvmTestE2e -Path $script:root -SkipModuleVersionCheck
        $skipped.Status | Should -Be 'skipped'
        $skipped.IgnoredFiles | Should -Be 1
        { Invoke-AvmTestE2e -Path $script:root -Example defaults -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*opted out*'
        $script:state.Calls.Count | Should -Be 0
    }

    It 'requires explicit scope and a safe group prefix before compiling or calling Azure' {
        { Invoke-AvmTestE2e -Path $script:root -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*explicit*SubscriptionId*'
        { Invoke-AvmTestE2e -Path $script:root -SubscriptionId $script:subscription `
                -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*explicit -Location*'
        { Invoke-AvmTestE2e -Path $script:root -SubscriptionId $script:subscription `
                -Location 'westus' -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*ResourceGroupPrefix*'
        { Invoke-AvmTestE2e -Path $script:root -SubscriptionId $script:subscription `
                -Location 'westus' -ResourceGroupPrefix 'not safe!' -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*safe -ResourceGroupPrefix*'
        $script:state.Calls.Count | Should -Be 0
    }

    It 'honors WhatIf by skipping all tool and Azure calls' {
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -WhatIf -SkipModuleVersionCheck
        $result.Status | Should -Be 'skipped'
        $result.RunsTotal | Should -Be 0
        $result.RunsSkipped | Should -Be 1
        $script:state.Calls.Count | Should -Be 0
        $script:state.Groups.Count | Should -Be 0
    }

    It 'refuses subscription-scoped templates before creating a group' {
        $script:state.Schema = 'https://schema.management.azure.com/schemas/2019-04-01/subscriptionDeploymentTemplate.json#'
        { Invoke-AvmTestE2e -Path $script:root -SubscriptionId $script:subscription `
                -Location 'westus' -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*Only resource-group templates*'
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count | Should -Be 0
    }

    It 'refuses uninspectable or cross-scope resources before creating a group' -ForEach @(
        @{ Resource = @{ type = 'Microsoft.Resources/deploymentScripts' }; Message = '*cannot be safely contained*' }
        @{ Resource = @{ type = 'Microsoft.Resources/resourceGroups' }; Message = '*cannot be safely contained*' }
        @{ Resource = @{ type = 'Microsoft.Authorization/locks' }; Message = '*cannot be safely contained*' }
        @{ Resource = @{ type = 'Microsoft.Authorization/roleAssignments' }; Message = '*cannot be safely contained*' }
        @{ Resource = @{ type = 'Microsoft.Resources/deployments'; properties = @{ templateLink = @{ uri = 'https://example.invalid/a' } } }; Message = '*without an inspectable inline template*' }
        @{ Resource = @{ type = 'Microsoft.Storage/storageAccounts'; scope = '[subscription()]' }; Message = '*cross-scope*' }
    ) {
        $script:state.Resources = @($Resource)
        { Invoke-AvmTestE2e -Path $script:root -SubscriptionId $script:subscription `
                -Location 'westus' -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage $Message
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count | Should -Be 0
    }

    It 'does not deploy when ARM validation, preview or group creation fails' -ForEach @(
        @{ Step = 'validate'; Code = 'validate-failed'; Field = 'FailOperation' }
        @{ Step = 'what-if'; Code = 'what-if-failed'; Field = 'FailOperation' }
        @{ Step = 'group-create'; Code = 'group-create-failed'; Field = 'CreateExit' }
        @{ Step = 'invalid-group-output'; Code = 'group-create-invalid'; Field = 'CreateOutput' }
        @{ Step = 'invalid-preview'; Code = 'what-if-invalid'; Field = 'WhatIfOutput' }
        @{ Step = 'empty-preview'; Code = 'what-if-unsafe'; Field = 'WhatIfOutput' }
        @{ Step = 'modified-preview'; Code = 'what-if-unsafe'; Field = 'WhatIfType' }
        @{ Step = 'outside-preview'; Code = 'what-if-unsafe'; Field = 'ResourceIdOverride' }
    ) {
        $value = switch ($Step) {
            'validate' { 'validate' }
            'what-if' { 'what-if' }
            'group-create' { 1 }
            'invalid-group-output' { 'not-json' }
            'invalid-preview' { '{}' }
            'empty-preview' { '{"changes":[]}' }
            'modified-preview' { 'Modify' }
            'outside-preview' {
                "/subscriptions/$script:subscription/resourceGroups/another-group/providers/Microsoft.Storage/storageAccounts/demo"
            }
        }
        $script:state.$Field = $value
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.RunsFailed | Should -Be 1
        $result.RunsPassed | Should -Be 0
        $result.Issues[0].Code | Should -Be "avm.bicep.e2e-$Code"
        $result.CleanupPending.Count | Should -Be 0
        $script:state.Groups.Count | Should -Be 0
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment' -and $_.Arguments[2] -eq 'create'
            }).Count | Should -Be 0
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 1
    }

    It 'reports a deployment failure while still cleaning up its group' {
        $script:state.FailOperation = 'create'
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.RunsFailed | Should -Be 1
        $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-deployment-failed'
        $script:state.Groups.Count | Should -Be 0
    }

    It 'refuses to reuse an existing resource group and never attempts to delete it' {
        $script:state.GroupExistsOutput = 'true'
        { Invoke-AvmTestE2e -Path $script:root `
                -SubscriptionId $script:subscription -Location 'westus' `
                -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*Refusing to use existing resource group*'
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and
                $_.Arguments[1] -in @('create', 'delete')
            }).Count | Should -Be 0
    }

    It 'marks a successful creation with an unobservable group as cleanup pending' {
        $script:state.GroupExistsOutput = 'false'
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.RunsPassed | Should -Be 0
        $result.RunsFailed | Should -Be 1
        $result.CleanupPending.Count | Should -Be 1
        $result.Issues[0].Message | Should -Match 'manual cleanup verification'
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 0
    }

    It 'reports a child-process exception or timeout while still cleaning up' -ForEach @(
        @{ Kind = 'exception'; Code = 'process-failed' }
        @{ Kind = 'timeout'; Code = 'process-timeout' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ FailureKind = $Kind } {
            param($FailureKind)
            $script:bicepE2eFailureKind = $FailureKind
            Mock Invoke-AvmBicepArmOperation {
                if ($script:bicepE2eFailureKind -eq 'timeout') {
                    throw [System.TimeoutException]::new('Fake Azure CLI timeout')
                }
                throw [AvmProcessException]::new('Fake Azure CLI process exception')
            }
        }
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be "avm.bicep.e2e-$Code"
        $result.CleanupPending.Count | Should -Be 0
        $script:state.Groups.Count | Should -Be 0
    }

    It 'fails on an unverified or unsuccessful deployment response and still deletes its group' -ForEach @(
        @{ Response = 'not-json'; State = 'Succeeded' }
        @{ Response = '{}'; State = 'Succeeded' }
        @{ Response = $null; State = 'Failed' }
    ) {
        $script:state.DeploymentOutput = $Response
        $script:state.DeploymentState = $State
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-deployment-unverified'
        $script:state.Groups.Count | Should -Be 0
    }

    It 'reports ownership mismatches and never deletes a group it cannot verify' {
        $script:state.ShowMismatch = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.RunsPassed | Should -Be 0
        $result.RunsFailed | Should -Be 1
        $result.CleanupPending.Count | Should -Be 1
        $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-cleanup-failed'
        $result.Issues[0].Message | Should -Match $result.CleanupPending[0]
        $script:state.Groups.Count | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 0
    }

    It 'reports a verification or deletion failure and keeps the group identified' -ForEach @(
        @{ Failure = 'show'; Field = 'ShowExit' }
        @{ Failure = 'delete'; Field = 'DeleteExit' }
    ) {
        $script:state.$Field = 1
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.CleanupPending.Count | Should -Be 1
        $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-cleanup-failed'
        $result.Issues[0].Message | Should -Match $result.CleanupPending[0]
        $script:state.Groups.Count | Should -Be 1
    }

    It 'marks unfinished deletion as failed and stops before creating further groups' {
        $second = Join-Path $script:root 'tests' 'e2e' 'second'
        $null = New-Item -ItemType Directory -Path $second -Force
        Set-Content -LiteralPath (Join-Path $second 'main.test.bicep') `
            -Value "param namePrefix string = 'demo'" -Encoding utf8NoBOM
        $script:state.DeletePersists = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.RunsTotal | Should -Be 1
        $result.RunsFailed | Should -Be 1
        $result.RunsSkipped | Should -Be 1
        $result.CleanupPending.Count | Should -Be 1
        $script:state.Groups.Count | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'create'
            }).Count | Should -Be 1
    }
}
