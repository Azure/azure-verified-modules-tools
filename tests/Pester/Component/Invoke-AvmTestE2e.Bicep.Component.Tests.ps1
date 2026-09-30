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
            LiveResources       = @{}
            ForeignContents     = @()
            Calls               = [System.Collections.Generic.List[object]]::new()
            GroupExistsOutput   = $null
            CreateExit          = 0
            CreateOutput        = $null
            ShowExit            = 0
            ShowMismatch        = $false
            DeleteExit          = 0
            DeletePersists      = $false
            ResourceDeleteExit  = 0
            ResourceDeletes     = 0
            ContentExit         = 0
            ContentOutput       = $null
            ForeignContentMode  = ''
            ForeignAfterDelete  = $false
            GroupTagAfterDelete = ''
            ChildTags           = $null
            CreateTimeout       = $false
            FailOperation       = ''
            WhatIfOutput        = $null
            WhatIfType          = 'Create'
            DeploymentState     = 'Succeeded'
            HistoryState        = 'Succeeded'
            MissingHistory      = $false
            MissingOperations   = $false
            OperationKind       = 'Create'
            OperationState      = 'Succeeded'
            DuplicateOperation = $false
            ForeignOperation    = $false
            DeploymentOutput    = $null
            DeploymentOutputs   = @{ account = @{ type = 'String'; value = 'deployed-account' } }
            PesterResult        = $null
            PesterExit          = 0
            PesterTimeout       = $false
            PesterInput         = $null
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
                param($FilePath, $ArgumentList, $TimeoutSec)
                $script:bicepE2eState.Calls.Add([pscustomobject]@{
                        FilePath   = $FilePath
                        Arguments  = [string[]]$ArgumentList
                        TimeoutSec = $TimeoutSec
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
                if ($FilePath -eq [System.Environment]::ProcessPath) {
                    $inputIndex = [array]::IndexOf($ArgumentList, '-InputPath')
                    $resultIndex = [array]::IndexOf($ArgumentList, '-ResultPath')
                    $script:bicepE2eState.PesterInput = Get-Content `
                        -LiteralPath $ArgumentList[$inputIndex + 1] -Raw -Encoding utf8 |
                        ConvertFrom-Json -AsHashtable
                    if ($script:bicepE2eState.PesterTimeout) {
                        throw [System.TimeoutException]::new('Fake Pester timeout')
                    }
                    if ($script:bicepE2eState.PesterExit -ne 0) {
                        return [pscustomobject]@{
                            ExitCode = 1; StdOut = ''; StdErr = 'Fake Pester setup error'
                        }
                    }
                    $summary = if ($null -ne $script:bicepE2eState.PesterResult) {
                        $script:bicepE2eState.PesterResult
                    }
                    else {
                        @{
                            Version = '5.7.1'; Total = 1; Passed = 1; Failed = 0
                            Skipped = 0; Inconclusive = 0; Filtered = 0; Issues = @()
                        }
                    }
                    [System.IO.File]::WriteAllText(
                        $ArgumentList[$resultIndex + 1],
                        ($summary | ConvertTo-Json -Depth 8 -Compress),
                        [System.Text.UTF8Encoding]::new($false))
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
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
                                type = 'Microsoft.Resources/resourceGroups'
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
                                    type = 'Microsoft.Resources/resourceGroups'
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
                if ($ArgumentList[0] -eq 'resource') {
                    $idIndex = [array]::IndexOf($ArgumentList, '--ids')
                    $resourceId = if ($idIndex -ge 0) { $ArgumentList[$idIndex + 1] } else { '' }
                    switch ($ArgumentList[1]) {
                        'list' {
                            if ($script:bicepE2eState.ContentExit -ne 0) {
                                return [pscustomobject]@{
                                    ExitCode = 1; StdOut = ''; StdErr = 'Fake inventory failure'
                                }
                            }
                            $contents = @($script:bicepE2eState.LiveResources.Values) +
                                @($script:bicepE2eState.ForeignContents)
                            if ($script:bicepE2eState.ForeignContentMode) {
                                $groupIndex = [array]::IndexOf($ArgumentList, '--resource-group')
                                $groupName = $ArgumentList[$groupIndex + 1]
                                if ($script:bicepE2eState.ForeignContentMode -eq 'duplicate') {
                                    $contents += $script:bicepE2eState.LiveResources.Values |
                                        Select-Object -First 1
                                }
                                else {
                                    $foreignGroup = if ($script:bicepE2eState.ForeignContentMode -eq 'outside') {
                                        'foreign-group'
                                    }
                                    else { $groupName }
                                    $contents += @{
                                        id = "/subscriptions/$script:bicepE2eSubscription/resourceGroups/$foreignGroup/providers/Microsoft.Storage/storageAccounts/foreign"
                                        type = 'Microsoft.Storage/storageAccounts'
                                        name = 'foreign'
                                    }
                                }
                            }
                            if ($script:bicepE2eState.ForeignAfterDelete -and
                                $script:bicepE2eState.ResourceDeletes -gt 0) {
                                $groupIndex = [array]::IndexOf($ArgumentList, '--resource-group')
                                $groupName = $ArgumentList[$groupIndex + 1]
                                $contents += @{
                                    id = "/subscriptions/$script:bicepE2eSubscription/resourceGroups/$groupName/providers/Microsoft.Storage/storageAccounts/foreign"
                                    type = 'Microsoft.Storage/storageAccounts'
                                    name = 'foreign'
                                }
                            }
                            $output = if ($null -ne $script:bicepE2eState.ContentOutput) {
                                $script:bicepE2eState.ContentOutput
                            }
                            else { ConvertTo-Json -InputObject @($contents) -Depth 8 -Compress }
                            return [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' }
                        }
                        'show' {
                            if (-not $script:bicepE2eState.LiveResources.ContainsKey($resourceId)) {
                                return [pscustomobject]@{
                                    ExitCode = 1; StdOut = ''; StdErr = '(ResourceNotFound) missing'
                                }
                            }
                            return [pscustomobject]@{
                                ExitCode = 0
                                StdOut = $script:bicepE2eState.LiveResources[$resourceId] |
                                    ConvertTo-Json -Depth 8 -Compress
                                StdErr = ''
                            }
                        }
                        'delete' {
                            if ($script:bicepE2eState.ResourceDeleteExit -ne 0) {
                                return [pscustomobject]@{
                                    ExitCode = 1; StdOut = ''; StdErr = 'Fake child deletion failure'
                                }
                            }
                            $null = $script:bicepE2eState.LiveResources.Remove($resourceId)
                            $script:bicepE2eState.ResourceDeletes++
                            if ($script:bicepE2eState.GroupTagAfterDelete) {
                                foreach ($group in $script:bicepE2eState.Groups.Values) {
                                    $group.tags['avm-e2e-run-id'] =
                                        $script:bicepE2eState.GroupTagAfterDelete
                                }
                            }
                            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                        }
                    }
                }
                if ($ArgumentList[0] -eq 'deployment') {
                    $groupIndex = [array]::IndexOf($ArgumentList, '--resource-group')
                    $groupName = $ArgumentList[$groupIndex + 1]
                    $deploymentNameIndex = [array]::IndexOf($ArgumentList, '--name')
                    $deploymentName = $ArgumentList[$deploymentNameIndex + 1]
                    $deploymentId = "/subscriptions/$script:bicepE2eSubscription/resourceGroups/$groupName/providers/Microsoft.Resources/deployments/$deploymentName"
                    if ($ArgumentList[1] -eq 'operation' -and $ArgumentList[3] -eq 'list') {
                        $operations = @()
                        if (-not $script:bicepE2eState.MissingOperations) {
                            $target = $script:bicepE2eState.LiveResources.Values |
                                Select-Object -First 1
                            $resourceId = if ($null -ne $script:bicepE2eState.ResourceIdOverride) {
                                $script:bicepE2eState.ResourceIdOverride
                            }
                            else { [string]$target.id }
                            $operation = @{
                                id = "$deploymentId/operations/one"
                                operationId = 'one'
                                properties = @{
                                    provisioningOperation = $script:bicepE2eState.OperationKind
                                    provisioningState = $script:bicepE2eState.OperationState
                                    targetResource = @{
                                        id = $resourceId
                                        resourceType = [string]$target.type
                                        resourceName = [string]$target.name
                                    }
                                }
                            }
                            $operations += $operation
                            if ($script:bicepE2eState.DuplicateOperation) {
                                $operations += $operation
                            }
                            if ($script:bicepE2eState.ForeignOperation) {
                                $operations += @{
                                    id = "$deploymentId/operations/foreign"
                                    operationId = 'foreign'
                                    properties = @{
                                        provisioningOperation = 'Create'
                                        provisioningState = 'Succeeded'
                                        targetResource = @{
                                            id = $resourceId.Replace($groupName, 'foreign-group')
                                            resourceType = [string]$target.type
                                            resourceName = [string]$target.name
                                        }
                                    }
                                }
                            }
                        }
                        return [pscustomobject]@{
                            ExitCode = 0
                            StdOut = ConvertTo-Json -InputObject @($operations) -Depth 10 -Compress
                            StdErr = ''
                        }
                    }
                    if ($ArgumentList[2] -eq 'show') {
                        if ($script:bicepE2eState.MissingHistory) {
                            return [pscustomobject]@{
                                ExitCode = 1; StdOut = ''; StdErr = '(DeploymentNotFound) missing'
                            }
                        }
                        return [pscustomobject]@{
                            ExitCode = 0
                            StdOut = @{
                                id = $deploymentId
                                name = $deploymentName
                                properties = @{ provisioningState = $script:bicepE2eState.HistoryState }
                            } | ConvertTo-Json -Depth 8 -Compress
                            StdErr = ''
                        }
                    }
                    $templateIndex = [array]::IndexOf($ArgumentList, '--template-file')
                    $script:bicepE2eState.TemporaryFile = $ArgumentList[$templateIndex + 1]
                    $script:bicepE2eState.CompiledJson = Get-Content `
                        -LiteralPath $script:bicepE2eState.TemporaryFile -Raw -Encoding utf8
                    $compiled = $script:bicepE2eState.CompiledJson | ConvertFrom-Json -AsHashtable
                    $resourceType = [string]$compiled.resources[0].type
                    $resourceName = [string]$compiled.resources[0].name
                    $parameterIndex = [array]::IndexOf($ArgumentList, '--parameters')
                    if ($parameterIndex -ge 0) {
                        $script:bicepE2eState.ParameterPath = $ArgumentList[$parameterIndex + 1].Substring(1)
                        $script:bicepE2eState.ParameterJson = Get-Content `
                            -LiteralPath $script:bicepE2eState.ParameterPath -Raw -Encoding utf8
                    }
                    if ($script:bicepE2eState.FailOperation -eq $ArgumentList[2] -and
                        $ArgumentList[2] -ne 'create') {
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Fake ARM failure' }
                    }
                    $resourceId = if ($null -ne $script:bicepE2eState.ResourceIdOverride) {
                        $script:bicepE2eState.ResourceIdOverride
                    }
                    else {
                        "/subscriptions/$script:bicepE2eSubscription/resourceGroups/$groupName/providers/$resourceType/$resourceName"
                    }
                    $preview = if ($null -ne $script:bicepE2eState.WhatIfOutput) {
                        $script:bicepE2eState.WhatIfOutput
                    }
                    else {
                        @{ changes = @(@{
                                    resourceId = $resourceId
                                    changeType = $script:bicepE2eState.WhatIfType
                                    after = @{ type = $resourceType; name = $resourceName }
                                }) } | ConvertTo-Json -Depth 8 -Compress
                    }
                    if ($ArgumentList[2] -eq 'create') {
                        $script:bicepE2eState.LiveResources[$resourceId] = @{
                            id = $resourceId
                            type = $resourceType
                            name = $resourceName
                        }
                        if ($null -ne $script:bicepE2eState.ChildTags) {
                            $script:bicepE2eState.LiveResources[$resourceId].tags =
                                $script:bicepE2eState.ChildTags
                        }
                        if ($script:bicepE2eState.CreateTimeout) {
                            $script:bicepE2eState.HistoryState = 'Canceled'
                            $script:bicepE2eState.OperationState = 'Canceled'
                            throw [System.TimeoutException]::new('Fake Create timeout after partial deployment')
                        }
                        if ($script:bicepE2eState.FailOperation -eq 'create') {
                            $script:bicepE2eState.HistoryState = 'Failed'
                            $script:bicepE2eState.OperationState = 'Failed'
                            return [pscustomobject]@{
                                ExitCode = 1; StdOut = ''; StdErr = 'Fake ARM failure'
                            }
                        }
                        $script:bicepE2eState.HistoryState = $script:bicepE2eState.DeploymentState
                    }
                    $deployment = @{
                        id = $deploymentId
                        name = $deploymentName
                        properties = @{
                            provisioningState = $script:bicepE2eState.DeploymentState
                            outputs           = $script:bicepE2eState.DeploymentOutputs
                        }
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
            -ResourceGroupPrefix 'avm-e2e' -Tokens @{ namePrefix = 'owned-account' } `
            -Parameters @{ administrator = 'private-value'; display = 'quote"slash\name' } `
            -SkipModuleVersionCheck

        $result.Status | Should -Be 'pass'
        $result.RunsTotal | Should -Be 1
        $result.RunsPassed | Should -Be 1
        $result.RunsFailed | Should -Be 0
        $result.AssertionResults.Count | Should -Be 1
        $result.AssertionResults[0].Status | Should -Be 'not-present'
        $result.AssertionResults[0].RunsPassed | Should -Be 0
        $result.CleanupPending.Count | Should -Be 0
        $result.WhatIfChanges.Count | Should -Be 1
        $script:state.Groups.Count | Should -Be 0
        $script:state.LiveResources.Count | Should -Be 0
        $script:state.ResourceDeletes | Should -Be 1
        ($script:state.CompiledJson | ConvertFrom-Json -AsHashtable).resources[0].name |
            Should -Be 'owned-account'
        ($script:state.ParameterJson | ConvertFrom-Json -AsHashtable).parameters.administrator.value |
            Should -Be 'private-value'
        ($script:state.ParameterJson | ConvertFrom-Json -AsHashtable).parameters.display.value |
            Should -Be 'quote"slash\name'
        (Get-Content -LiteralPath $script:sourcePath -Raw) | Should -BeExactly $original
        (Test-Path -LiteralPath $script:state.TemporaryFile) | Should -BeFalse
        (Test-Path -LiteralPath $script:state.ParameterPath) | Should -BeFalse
        $sequence = @($script:state.Calls | ForEach-Object {
                if ($_.FilePath -eq 'fake-bicep') { 'build' }
                elseif ($_.Arguments[0] -eq 'group') { 'group-' + $_.Arguments[1] }
                elseif ($_.Arguments[0] -eq 'resource') { 'resource-' + $_.Arguments[1] }
                elseif ($_.Arguments[1] -eq 'operation') { 'operation-list' }
                else { $_.Arguments[2] }
            })
        $sequence[0..5] | Should -Be @('build', 'group-exists', 'group-create',
            'validate', 'what-if', 'create')
        [array]::IndexOf($sequence, 'resource-list') |
            Should -BeLessThan ([array]::IndexOf($sequence, 'resource-delete'))
        [array]::IndexOf($sequence, 'resource-delete') |
            Should -BeLessThan ([array]::IndexOf($sequence, 'group-delete'))
        $create = $script:state.Calls |
            Where-Object { $_.Arguments[0] -eq 'deployment' -and $_.Arguments[2] -eq 'create' } |
            Select-Object -First 1
        $create.Arguments | Should -Contain '--mode'
        $create.Arguments | Should -Contain 'Incremental'
        $create.Arguments | Should -Contain $script:subscription
        $create.Arguments | Should -Not -Contain 'private-value'
        @($script:state.Calls | Where-Object {
                $_.FilePath -eq [System.Environment]::ProcessPath
            }).Count | Should -Be 0
    }

    It 'runs case-local Pester after deployment and passes ARM outputs without leaking them into argv' {
        $caseDirectory = Split-Path -Parent $script:sourcePath
        $testPath = Join-Path $caseDirectory 'deployed.tests.ps1'
        Set-Content -LiteralPath $testPath `
            -Value "Describe 'deployed' { It 'passes' { `$true | Should -BeTrue } }" `
            -Encoding utf8NoBOM
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'pass'
        $result.RunsPassed | Should -Be 1
        $result.AssertionResults.Count | Should -Be 1
        $result.AssertionResults[0].Case | Should -Be 'tests/e2e/defaults'
        $result.AssertionResults[0].Status | Should -Be 'pass'
        $result.AssertionResults[0].FilesProcessed | Should -Be 1
        $result.AssertionResults[0].RunsPassed | Should -Be 1
        $script:state.PesterInput.Mode | Should -Be 'E2e'
        $script:state.PesterInput.Files | Should -Be @($testPath)
        $script:state.PesterInput.TestInputData.ModuleTestFolderPath |
            Should -Be $caseDirectory
        $script:state.PesterInput.TestInputData.DeploymentOutputs.account.value |
            Should -Be 'deployed-account'
        $script:state.Groups.Count | Should -Be 0
        ($script:state.Calls | Where-Object {
                $_.FilePath -eq [System.Environment]::ProcessPath
            } | Select-Object -First 1).TimeoutSec | Should -Be 1800
        $sequence = @($script:state.Calls | ForEach-Object {
                if ($_.FilePath -eq [System.Environment]::ProcessPath) { 'pester' }
                elseif ($_.Arguments[0] -eq 'deployment') { $_.Arguments[2] }
                else { $_.Arguments[1] }
            })
        [array]::IndexOf($sequence, 'create') |
            Should -BeLessThan ([array]::IndexOf($sequence, 'pester'))
        [array]::IndexOf($sequence, 'pester') |
            Should -BeLessThan ([array]::IndexOf($sequence, 'delete'))
        @($script:state.Calls | Where-Object {
                $_.FilePath -eq [System.Environment]::ProcessPath -and
                $_.Arguments -contains 'deployed-account'
            }).Count | Should -Be 0
    }

    It 'fails a Pester assertion and preserves its diagnostic while deleting the owned group' {
        $caseDirectory = Split-Path -Parent $script:sourcePath
        $testPath = Join-Path $caseDirectory 'deployed.Tests.ps1'
        Set-Content -LiteralPath $testPath -Value 'authored assertion' -Encoding utf8NoBOM
        $script:state.PesterResult = @{
            Version = '5.7.1'; Total = 1; Passed = 0; Failed = 1
            Skipped = 0; Inconclusive = 0; Filtered = 0
            Issues = @(@{
                    File = $testPath; Line = 7; Column = 0; Severity = 'error'
                    Code = 'avm.bicep.pester-failed'; Message = 'deployed: Expected resource to exist.'
                })
        }
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.RunsPassed | Should -Be 0
        $result.RunsFailed | Should -Be 1
        $result.AssertionResults[0].Status | Should -Be 'fail'
        $result.AssertionResults[0].RunsFailed | Should -Be 1
        $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-assertion-failed'
        $result.Issues[0].File | Should -Be $testPath
        $result.Issues[0].Line | Should -Be 7
        $result.Issues[0].Message | Should -Match 'tests/e2e/defaults.*Expected resource'
        $result.CleanupPending.Count | Should -Be 0
        $script:state.Groups.Count | Should -Be 0
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 1
    }

    It 'never treats skipped, empty or filtered authored Pester suites as passed' -ForEach @(
        @{
            Summary = @{
                Version = '5.7.1'; Total = 0; Passed = 0; Failed = 0
                Skipped = 0; Inconclusive = 0; Filtered = 0; Issues = @()
            }
            Code = 'avm.bicep.e2e-assertion-empty'
        }
        @{
            Summary = @{
                Version = '5.7.1'; Total = 2; Passed = 1; Failed = 0
                Skipped = 1; Inconclusive = 0; Filtered = 0; Issues = @()
            }
            Code = 'avm.bicep.e2e-assertion-incomplete'
        }
        @{
            Summary = @{
                Version = '5.7.1'; Total = 1; Passed = 0; Failed = 0
                Skipped = 0; Inconclusive = 0; Filtered = 1; Issues = @()
            }
            Code = 'avm.bicep.e2e-assertion-empty'
        }
        @{
            Summary = @{
                Version = '5.7.1'; Total = 1; Passed = 0; Failed = 0
                Skipped = 1; Inconclusive = 0; Filtered = 0
                Issues = @(@{
                        File = ''; Line = 2; Column = 0; Severity = 'error'
                        Code = 'avm.bicep.pester-skipped'; Message = 'deployed: Pester reported Skipped.'
                    })
            }
            Code = 'avm.bicep.e2e-assertion-skipped'
        }
    ) {
        Set-Content -LiteralPath (Join-Path (Split-Path $script:sourcePath) 'assert.tests.ps1') `
            -Value 'authored assertion' -Encoding utf8NoBOM
        $script:state.PesterResult = $Summary
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.RunsFailed | Should -Be 1
        $result.AssertionResults[0].Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be $Code
        $result.CleanupPending.Count | Should -Be 0
        $script:state.Groups.Count | Should -Be 0
    }

    It 'fails and cleans up when the Pester runner errors, returns invalid data or times out' -ForEach @(
        @{ Kind = 'exit'; Code = 'assertion-runner-failed' }
        @{ Kind = 'malformed'; Code = 'assertion-runner-failed' }
        @{ Kind = 'timeout'; Code = 'assertion-timeout' }
    ) {
        Set-Content -LiteralPath (Join-Path (Split-Path $script:sourcePath) 'assert.tests.ps1') `
            -Value 'authored assertion' -Encoding utf8NoBOM
        switch ($Kind) {
            'exit' { $script:state.PesterExit = 1 }
            'malformed' { $script:state.PesterResult = 'not-json' }
            'timeout' { $script:state.PesterTimeout = $true }
        }
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.AssertionResults[0].Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be "avm.bicep.e2e-$Code"
        $result.CleanupPending.Count | Should -Be 0
        $script:state.Groups.Count | Should -Be 0
    }

    It 'retains both assertion and cleanup errors when ownership cannot be verified' {
        Set-Content -LiteralPath (Join-Path (Split-Path $script:sourcePath) 'assert.tests.ps1') `
            -Value 'authored assertion' -Encoding utf8NoBOM
        $script:state.PesterResult = @{
            Version = '5.7.1'; Total = 1; Passed = 0; Failed = 1
            Skipped = 0; Inconclusive = 0; Filtered = 0
            Issues = @(@{
                    File = ''; Line = 0; Column = 0; Severity = 'error'
                    Code = 'avm.bicep.pester-failed'; Message = 'Deployed resource was absent.'
                })
        }
        $script:state.ShowMismatch = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.e2e-assertion-failed'
        $result.Issues.Code | Should -Contain 'avm.bicep.e2e-cleanup-failed'
        $result.CleanupPending.Count | Should -Be 1
        $script:state.Groups.Count | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 0
    }

    It 'rejects invalid deployment outputs before running assertions and still deletes the group' {
        Set-Content -LiteralPath (Join-Path (Split-Path $script:sourcePath) 'assert.tests.ps1') `
            -Value 'authored assertion' -Encoding utf8NoBOM
        $script:state.DeploymentOutputs = 'not-an-output-object'
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-assertion-runner-failed'
        $result.Issues[0].Message | Should -Match 'invalid outputs'
        $script:state.PesterInput | Should -BeNullOrEmpty
        $script:state.Groups.Count | Should -Be 0
    }

    It 'continues to a separate group after a failed assertion was cleaned up' {
        $second = Join-Path $script:root 'tests' 'e2e' 'second'
        $null = New-Item -ItemType Directory -Path $second -Force
        Set-Content -LiteralPath (Join-Path $second 'main.test.bicep') `
            -Value "param namePrefix string = 'demo'" -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path (Split-Path $script:sourcePath) 'assert.tests.ps1') `
            -Value 'authored assertion' -Encoding utf8NoBOM
        $script:state.PesterResult = @{
            Version = '5.7.1'; Total = 1; Passed = 0; Failed = 1
            Skipped = 0; Inconclusive = 0; Filtered = 0; Issues = @()
        }
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.RunsTotal | Should -Be 2
        $result.RunsFailed | Should -Be 1
        $result.RunsPassed | Should -Be 1
        $result.AssertionResults.Status | Should -Be @('fail', 'not-present')
        $script:state.Groups.Count | Should -Be 0
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 2
    }

    It 'does not run nested examples assertions against the parent example' {
        $parentAssertion = Join-Path (Split-Path $script:sourcePath) 'parent.tests.ps1'
        Set-Content -LiteralPath $parentAssertion -Value 'parent' -Encoding utf8NoBOM
        $nested = Join-Path (Split-Path $script:sourcePath) 'child'
        $null = New-Item -ItemType Directory -Path $nested -Force
        Set-Content -LiteralPath (Join-Path $nested 'main.test.bicep') `
            -Value 'param namePrefix string' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $nested 'child.tests.ps1') `
            -Value 'child' -Encoding utf8NoBOM
        $result = Invoke-AvmTestE2e -Path $script:root -Example defaults `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'pass'
        $result.AssertionResults[0].FilesProcessed | Should -Be 1
        $script:state.PesterInput.Files | Should -Be @($parentAssertion)
        $script:state.Groups.Count | Should -Be 0
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

    It 'requires explicit scope and a safe group prefix before calling Azure' {
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
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count |
            Should -Be 0
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

    It 'refuses unsupported subscription resources before creating a group' {
        $script:state.Schema = 'https://schema.management.azure.com/schemas/2019-04-01/subscriptionDeploymentTemplate.json#'
        { Invoke-AvmTestE2e -Path $script:root -SubscriptionId $script:subscription `
                -TenantId '00000000-0000-0000-0000-000000000002' `
                -Location 'westus' -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*unsupported sub resource type*'
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

    It 'retains foreign contents introduced before deployment when validation fails' {
        $script:state.FailOperation = 'validate'
        $script:state.ForeignContentMode = 'foreign'
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.e2e-validate-failed'
        $result.Issues.Code | Should -Contain 'avm.bicep.e2e-cleanup-failed'
        $script:state.Groups.Count | Should -Be 1
        $result.CleanupPending | Should -Contain @($script:state.Groups.Keys)[0]
        @($result.CleanupPending | Where-Object {
                $_ -match '/storageAccounts/foreign$'
            }).Count | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 0
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

    It 'keeps the group and every child when <Case> makes cleanup ownership ambiguous' -ForEach @(
        @{ Case = 'an untracked sibling'; Change = 'foreign'; Field = 'ForeignContentMode' }
        @{ Case = 'a foreign group in inventory'; Change = 'outside'; Field = 'ForeignContentMode' }
        @{ Case = 'a duplicate inventory entry'; Change = 'duplicate'; Field = 'ForeignContentMode' }
        @{ Case = 'an altered child tag'; Change = 'tag'; Field = 'ChildTags' }
        @{ Case = 'a case-variant child tag'; Change = 'case-tag'; Field = 'ChildTags' }
        @{ Case = 'a missing deployment history'; Change = 'history'; Field = 'MissingHistory' }
        @{ Case = 'missing operation history'; Change = 'operations'; Field = 'MissingOperations' }
        @{ Case = 'an Update operation'; Change = 'update'; Field = 'OperationKind' }
        @{ Case = 'a NoChange operation'; Change = 'unchanged'; Field = 'OperationKind' }
        @{ Case = 'a nonterminal operation'; Change = 'running'; Field = 'OperationState' }
        @{ Case = 'a repeated operation ID'; Change = 'duplicate-operation'; Field = 'DuplicateOperation' }
        @{ Case = 'a foreign operation target'; Change = 'foreign-operation'; Field = 'ForeignOperation' }
        @{ Case = 'an incomplete resource inventory'; Change = 'missing-inventory'; Field = 'ContentOutput' }
        @{ Case = 'invalid resource inventory'; Change = 'invalid-inventory'; Field = 'ContentOutput' }
        @{ Case = 'a failed resource inventory request'; Change = 'inventory-error'; Field = 'ContentExit' }
        @{ Case = 'a failed individual child deletion'; Change = 'child-delete'; Field = 'ResourceDeleteExit' }
    ) {
        $value = switch ($Change) {
            foreign { 'foreign' }
            outside { 'outside' }
            duplicate { 'duplicate' }
            tag { @{ 'avm-e2e-run-id' = 'another-run' } }
            'case-tag' { @{ 'AVM-E2E-RUN-ID' = 'another-run' } }
            history { $true }
            operations { $true }
            update { 'Update' }
            unchanged { 'NoChange' }
            running { 'Running' }
            'duplicate-operation' { $true }
            'foreign-operation' { $true }
            'missing-inventory' { '[]' }
            'invalid-inventory' { '{}' }
            'inventory-error' { 1 }
            'child-delete' { 1 }
        }
        $script:state.$Field = $value
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.RunsPassed | Should -Be 0
        $result.RunsFailed | Should -Be 1
        $result.Issues.Code | Should -Contain 'avm.bicep.e2e-cleanup-failed'
        $script:state.Groups.Count | Should -Be 1
        $script:state.LiveResources.Count | Should -Be 1
        $script:state.ResourceDeletes | Should -Be 0
        $groupName = @($script:state.Groups.Keys)[0]
        $result.CleanupPending | Should -Contain $groupName
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 0
    }

    It 'leaves the group pending if foreign content arrives after individually deleting its proven child' {
        $script:state.ForeignAfterDelete = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.RunsPassed | Should -Be 0
        $script:state.ResourceDeletes | Should -Be 1
        $script:state.Groups.Count | Should -Be 1
        $result.CleanupPending | Should -Contain @($script:state.Groups.Keys)[0]
        @($result.CleanupPending | Where-Object {
                $_ -match '/storageAccounts/foreign$'
            }).Count | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 0
    }

    It 'leaves a retagged group pending after deleting only the already verified child' {
        $script:state.GroupTagAfterDelete = 'another-run'
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $script:state.ResourceDeletes | Should -Be 1
        $script:state.Groups.Count | Should -Be 1
        $result.CleanupPending | Should -Contain @($script:state.Groups.Keys)[0]
        $result.Issues.Code | Should -Contain 'avm.bicep.e2e-cleanup-failed'
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'delete'
            }).Count | Should -Be 0
    }

    It 'removes only the proven partial resource after a terminal cancelled Create timeout' {
        $script:state.CreateTimeout = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.e2e-process-timeout'
        $result.CleanupPending.Count | Should -Be 0
        $script:state.ResourceDeletes | Should -Be 1
        $script:state.LiveResources.Count | Should -Be 0
        $script:state.Groups.Count | Should -Be 0
    }

    It 'preserves partial resources after cancellation when operation history is incomplete' {
        $script:state.CreateTimeout = $true
        $script:state.MissingOperations = $true
        $result = Invoke-AvmTestE2e -Path $script:root `
            -SubscriptionId $script:subscription -Location 'westus' `
            -ResourceGroupPrefix 'avm-e2e' -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.e2e-process-timeout'
        $result.Issues.Code | Should -Contain 'avm.bicep.e2e-cleanup-failed'
        $result.CleanupPending.Count | Should -BeGreaterThan 0
        $script:state.ResourceDeletes | Should -Be 0
        $script:state.LiveResources.Count | Should -Be 1
        $script:state.Groups.Count | Should -Be 1
    }
}
