#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $script:subscriptionId = '00000000-0000-0000-0000-000000000001'
    $script:groupSchema = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep ARM integration tier' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ('bicep arm ' + [guid]::NewGuid().ToString('N'))
        $caseDir = Join-Path $script:root 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $caseDir -Force
        Set-Content -LiteralPath (Join-Path $script:root 'main.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        $script:sourcePath = Join-Path $caseDir 'main.test.bicep'
        Set-Content -LiteralPath $script:sourcePath `
            -Value "param namePrefix string = '#_namePrefix_#'" -Encoding utf8NoBOM

        $script:state = [pscustomobject]@{
            Schema        = $script:groupSchema
            GroupExists   = 'true'
            BicepExit     = 0
            FailOperation = ''
            WhatIfJson    = '{"changes":[{"resourceId":"/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/existing-test/providers/Microsoft.Storage/storageAccounts/demo","changeType":"Create"}]}'
            CompiledJson  = ''
            TemporaryFile = ''
            ParameterJson = ''
            ParameterPath = ''
            Calls         = [System.Collections.Generic.List[object]]::new()
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ State = $script:state } {
            param($State)
            $script:bicepArmState = $State
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Path = 'fake-bicep'; Version = 'pinned'; Source = 'stub' }
            }
            Mock Get-Command {
                [pscustomobject]@{ Source = 'fake-az' }
            } -ParameterFilter { $Name -eq 'az' }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $script:bicepArmState.Calls.Add([pscustomobject]@{
                        FilePath  = $FilePath
                        Arguments = [string[]]$ArgumentList
                    })
                if ($FilePath -eq 'fake-bicep') {
                    if ($script:bicepArmState.BicepExit -ne 0) {
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Bicep compilation error' }
                    }
                    $template = [ordered]@{
                        '$schema' = $script:bicepArmState.Schema
                        resources = @([ordered]@{ type = 'Microsoft.Storage/storageAccounts'; name = '#_namePrefix_#' })
                    }
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = $template | ConvertTo-Json -Depth 8 -Compress
                        StdErr   = ''
                    }
                }
                if ($ArgumentList[0] -eq 'group' -and $ArgumentList[1] -eq 'exists') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = $script:bicepArmState.GroupExists
                        StdErr   = ''
                    }
                }
                if ($ArgumentList[0] -eq 'deployment') {
                    $index = [array]::IndexOf($ArgumentList, '--template-file') + 1
                    $script:bicepArmState.TemporaryFile = $ArgumentList[$index]
                    $script:bicepArmState.CompiledJson = Get-Content `
                        -LiteralPath $ArgumentList[$index] -Raw -Encoding utf8
                    $parameterIndex = [array]::IndexOf($ArgumentList, '--parameters')
                    if ($parameterIndex -ge 0) {
                        $script:bicepArmState.ParameterPath = $ArgumentList[$parameterIndex + 1].Substring(1)
                        $script:bicepArmState.ParameterJson = Get-Content `
                            -LiteralPath $script:bicepArmState.ParameterPath -Raw -Encoding utf8
                    }
                    if ($script:bicepArmState.FailOperation -eq $ArgumentList[2]) {
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Fake ARM rejection' }
                    }
                    $output = if ($ArgumentList[2] -eq 'what-if') {
                        $script:bicepArmState.WhatIfJson
                    }
                    else { '{"status":"Succeeded"}' }
                    return [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' }
                }
                throw "Unexpected process: $FilePath $($ArgumentList -join ' ')"
            }
        }
    }

    It 'validates and previews escaped tokens without changing authored files' {
        $original = Get-Content -LiteralPath $script:sourcePath -Raw
        $result = Invoke-AvmTestIntegration -Path $script:root `
            -SubscriptionId $script:subscriptionId -ResourceGroupName 'existing-test' `
            -Tokens @{ namePrefix = 'avm"demo\test' } -SkipModuleVersionCheck

        $result.Status | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 1
        $result.RunsTotal | Should -Be 2
        $result.RunsPassed | Should -Be 2
        $result.RunsFailed | Should -Be 0
        $result.WhatIfChanges.Count | Should -Be 1
        $result.WhatIfChanges[0].ChangeType | Should -Be 'Create'
        ($script:state.CompiledJson | ConvertFrom-Json -AsHashtable).resources[0].name |
            Should -Be 'avm"demo\test'
        (Get-Content -LiteralPath $script:sourcePath -Raw) | Should -BeExactly $original
        (Test-Path -LiteralPath $script:state.TemporaryFile) | Should -BeFalse
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment'
            }).Count | Should -Be 2
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'group' -and $_.Arguments[1] -eq 'create'
            }).Count | Should -Be 0
        $validate = $script:state.Calls |
            Where-Object { $_.Arguments[0] -eq 'deployment' -and $_.Arguments[2] -eq 'validate' } |
            Select-Object -First 1
        $validate.Arguments | Should -Contain $script:subscriptionId
        $validate.Arguments | Should -Contain 'existing-test'
        $validate.Arguments | Should -Contain '--no-prompt'
    }

    It 'does not create a missing resource group or attempt ARM operations' {
        $script:state.GroupExists = 'false'
        { Invoke-AvmTestIntegration -Path $script:root `
                -SubscriptionId $script:subscriptionId -ResourceGroupName 'missing' `
                -Tokens @{ namePrefix = 'avm' } -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*must already exist*'
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment'
            }).Count | Should -Be 0
    }

    It 'rejects an invalid resource-group existence response rather than assuming the group is absent' {
        $script:state.GroupExists = 'not-a-boolean'
        { Invoke-AvmTestIntegration -Path $script:root `
                -SubscriptionId $script:subscriptionId -ResourceGroupName 'existing-test' `
                -Tokens @{ namePrefix = 'avm' } -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*invalid resource-group existence result*'
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment'
            }).Count | Should -Be 0
    }

    It 'rejects an unresolved token before invoking Azure CLI' {
        { Invoke-AvmTestIntegration -Path $script:root `
                -SubscriptionId $script:subscriptionId -ResourceGroupName 'existing-test' `
                -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*Unresolved*namePrefix*'
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count |
            Should -Be 0
    }

    It 'reports an ARM validation failure and skips what-if for that example' {
        $script:state.FailOperation = 'validate'
        $result = Invoke-AvmTestIntegration -Path $script:root `
            -SubscriptionId $script:subscriptionId -ResourceGroupName 'existing-test' `
            -Tokens @{ namePrefix = 'avm' } -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.RunsTotal | Should -Be 1
        $result.RunsPassed | Should -Be 0
        $result.RunsFailed | Should -Be 1
        $result.RunsSkipped | Should -Be 1
        $result.Issues[0].File | Should -Be 'tests/e2e/defaults/main.test.bicep'
        $result.Issues[0].Message | Should -Match 'Fake ARM rejection'
        @($script:state.Calls | Where-Object {
                $_.Arguments[0] -eq 'deployment' -and $_.Arguments[2] -eq 'what-if'
            }).Count | Should -Be 0
    }

    It 'rejects an invalid what-if response instead of reporting success' {
        $script:state.WhatIfJson = '{}'
        { Invoke-AvmTestIntegration -Path $script:root `
                -SubscriptionId $script:subscriptionId -ResourceGroupName 'existing-test' `
                -Tokens @{ namePrefix = 'avm' } -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*no JSON changes array*'
    }

    It 'skips ignored examples and rejects an explicitly selected ignored example' {
        Set-Content -LiteralPath (Join-Path (Split-Path $script:sourcePath) '.e2eignore') `
            -Value 'not ready' -Encoding utf8NoBOM
        $result = Invoke-AvmTestIntegration -Path $script:root -SkipModuleVersionCheck
        $result.Status | Should -Be 'skipped'
        $result.IgnoredFiles | Should -Be 1
        $result.RunsTotal | Should -Be 0
        $script:state.Calls.Count | Should -Be 0
        { Invoke-AvmTestIntegration -Path $script:root -Example 'defaults' -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*opted out*'
    }

    It 'requires a unique selector for nested scopes and accepts a relative path' {
        $child = Join-Path $script:root 'child'
        $nested = Join-Path $child 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $nested -Force
        Set-Content -LiteralPath (Join-Path $child 'main.bicep') `
            -Value 'param child string' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $nested 'main.test.bicep') `
            -Value "param namePrefix string = '#_namePrefix_#'" -Encoding utf8NoBOM

        { Invoke-AvmTestIntegration -Path $script:root -Recurse -Example defaults `
                -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*Ambiguous*'
        $result = Invoke-AvmTestIntegration -Path $script:root -Recurse `
            -Example 'child/tests/e2e/defaults' -Operation Validate `
            -SubscriptionId $script:subscriptionId -ResourceGroupName 'existing-test' `
            -Tokens @{ namePrefix = 'avm' } -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 1
        $result.RunsTotal | Should -Be 1
    }

    It 'routes compiled <Scope> templates to the correct Azure CLI scope' -ForEach @(
        @{ Scope = 'group'; Schema = 'deploymentTemplate'; Flag = '--resource-group' }
        @{ Scope = 'sub'; Schema = 'subscriptionDeploymentTemplate'; Flag = '--location' }
        @{ Scope = 'mg'; Schema = 'managementGroupDeploymentTemplate'; Flag = '--management-group-id' }
        @{ Scope = 'tenant'; Schema = 'tenantDeploymentTemplate'; Flag = '--location' }
    ) {
        $script:state.Schema = "https://schema.management.azure.com/schemas/2019-04-01/$Schema.json#"
        $result = Invoke-AvmTestIntegration -Path $script:root -Operation Validate `
            -SubscriptionId $script:subscriptionId -ResourceGroupName 'existing-test' `
            -Location 'westeurope' -ManagementGroupId 'test-management-group' `
            -Tokens @{ namePrefix = 'avm' } -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $call = $script:state.Calls |
            Where-Object { $_.Arguments[0] -eq 'deployment' } |
            Select-Object -First 1
        $call.Arguments[1] | Should -Be $Scope
        $call.Arguments | Should -Contain $Flag
        $call.Arguments | Should -Contain $script:subscriptionId
    }

    It 'requires management-group and location inputs before invoking ARM' {
        $script:state.Schema = 'https://schema.management.azure.com/schemas/2019-08-01/managementGroupDeploymentTemplate.json#'
        { Invoke-AvmTestIntegration -Path $script:root -Operation Validate `
                -SubscriptionId $script:subscriptionId -Location 'westeurope' `
                -Tokens @{ namePrefix = 'avm' } -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*ManagementGroupId*'
        { Invoke-AvmTestIntegration -Path $script:root -Operation Validate `
                -SubscriptionId $script:subscriptionId -ManagementGroupId 'demo' `
                -Tokens @{ namePrefix = 'avm' } -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*Location*'
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count |
            Should -Be 0
    }

    It 'rejects a malformed token file before making any Azure call' {
        $tokenPath = Join-Path $script:root 'test-tokens.json'
        Set-Content -LiteralPath $tokenPath -Value '{"namePrefix":42}' -Encoding utf8NoBOM
        { Invoke-AvmTestIntegration -Path $script:root -Operation Validate `
                -SubscriptionId $script:subscriptionId -ResourceGroupName 'existing-test' `
                -TokenFile 'test-tokens.json' -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*must contain a string*'
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count | Should -Be 0
    }

    It 'passes additional parameters through a temporary JSON file, not argv' {
        $result = Invoke-AvmTestIntegration -Path $script:root -Operation Validate `
            -SubscriptionId $script:subscriptionId -ResourceGroupName 'existing-test' `
            -Tokens @{ namePrefix = 'avm' } `
            -Parameters @{ administrator = 'value-with-"quotes"'; suffix = '#_namePrefix_#' } `
            -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $actual = $script:state.ParameterJson | ConvertFrom-Json -AsHashtable
        $actual.parameters.administrator.value | Should -Be 'value-with-"quotes"'
        $actual.parameters.suffix.value | Should -Be 'avm'
        (Test-Path -LiteralPath $script:state.ParameterPath) | Should -BeFalse
        $deployment = $script:state.Calls |
            Where-Object { $_.Arguments[0] -eq 'deployment' } |
            Select-Object -First 1
        $deployment.Arguments | Should -Not -Contain 'value-with-"quotes"'
        $deployment.Arguments | Should -Contain ('@' + $script:state.ParameterPath)
    }

    It 'substitutes tokens in a copied parameter file without modifying the original' {
        $parameters = Join-Path $script:root 'parameters.json'
        $original = '{"parameters":{"namePrefix":{"value":"#_namePrefix_#"}}}'
        Set-Content -LiteralPath $parameters -Value $original -Encoding utf8NoBOM
        $result = Invoke-AvmTestIntegration -Path $script:root -Operation Validate `
            -SubscriptionId $script:subscriptionId -ResourceGroupName 'existing-test' `
            -Tokens @{ namePrefix = 'avm' } -ParameterFile 'parameters.json' `
            -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        ($script:state.ParameterJson | ConvertFrom-Json -AsHashtable).parameters.namePrefix.value |
            Should -Be 'avm'
        (Get-Content -LiteralPath $parameters -Raw).Trim() | Should -BeExactly $original
    }

    It 'does not start Azure commands when the Bicep compiler fails' {
        $script:state.BicepExit = 1
        { Invoke-AvmTestIntegration -Path $script:root `
                -SubscriptionId $script:subscriptionId -ResourceGroupName 'existing-test' `
                -Tokens @{ namePrefix = 'avm' } -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*Bicep compilation error*'
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count | Should -Be 0
    }
}
