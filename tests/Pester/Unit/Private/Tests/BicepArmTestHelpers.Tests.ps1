#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:subscription = '00000000-0000-0000-0000-000000000001'
    $script:groupSchema = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep ARM test token helpers' {
    It 'merges an explicit subscription and a JSON token file' {
        $root = Join-Path $TestDrive 'token-sources'
        $null = New-Item -ItemType Directory -Path $root -Force
        Set-Content -LiteralPath (Join-Path $root 'tokens.json') `
            -Value '{"namePrefix":"a\\b","moduleVersion":"1.0.0"}' -Encoding utf8NoBOM
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $root; S = $script:subscription } {
            param($R, $S)
            $map = Get-AvmBicepTestTokenMap -Root $R -SubscriptionId $S -TokenFile 'tokens.json'
            $map['subscriptionId'] | Should -Be $S
            $map['namePrefix'] | Should -Be 'a\b'
            $map['moduleVersion'] | Should -Be '1.0.0'
            $map.Count | Should -Be 3
        }
    }

    It 'rejects conflicting, non-string and scope-override tokens' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive; S = $script:subscription } {
            param($R, $S)
            { Get-AvmBicepTestTokenMap -Root $R -SubscriptionId $S `
                    -Tokens @{ namePrefix = 42 } } |
                Should -Throw -ExpectedMessage '*must contain a string*'
            { Get-AvmBicepTestTokenMap -Root $R -SubscriptionId $S `
                    -Tokens @{ subscriptionId = $S } } |
                Should -Throw -ExpectedMessage '*explicit scope parameter*'
            { Get-AvmBicepTestTokenMap -Root $R -SubscriptionId $S `
                    -TokenFile 'tokens.json' -Tokens @{ namePrefix = 'avm' } } |
                Should -Throw -ExpectedMessage '*not both*'
        }
    }

    It 'generates run-unique scoped tokens without replacing a custom name prefix' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive; S = $script:subscription } {
            param($R, $S)
            $runId = '0123456789abcdef0123456789abcdef'
            $tenantId = '00000000-0000-0000-0000-000000000002'
            $generated = Get-AvmBicepTestTokenMap -Root $R -SubscriptionId $S `
                -TenantId $tenantId -RunId $runId
            $generated['tenantId'] | Should -Be $tenantId
            $generated['avmE2eRunId'] | Should -Be $runId
            $generated['avmE2eSuffix'] | Should -Be '0123456789'
            $generated['namePrefix'] | Should -Be 'avm0123456789'

            $custom = Get-AvmBicepTestTokenMap -Root $R -SubscriptionId $S `
                -TenantId $tenantId -RunId $runId `
                -Tokens @{ namePrefix = 'team#_avmE2eSuffix_#' }
            $custom['namePrefix'] | Should -Be 'team0123456789'
            (Get-AvmBicepTestTokenMap -Root $R -SubscriptionId $S `
                    -RunId $runId -Tokens @{ namePrefix = 'unchanged' })['namePrefix'] |
                Should -Be 'unchanged'
            { Get-AvmBicepTestTokenMap -Root $R -SubscriptionId $S `
                    -TenantId $tenantId -RunId $runId `
                    -Tokens @{ avmE2eSuffix = 'custom' } } |
                Should -Throw -ExpectedMessage '*Duplicate*'
            { Get-AvmBicepTestTokenMap -Root $R -SubscriptionId $S `
                    -TenantId $tenantId -Tokens @{ tenantId = 'another' } } |
                Should -Throw -ExpectedMessage '*explicit scope parameter*'
        }
    }

    It 'escapes inserted JSON strings and refuses missing tokens' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive; S = $script:subscription } {
            param($R, $S)
            $tokens = Get-AvmBicepTestTokenMap -Root $R -SubscriptionId $S `
                -Tokens @{ namePrefix = 'quote"slash\value' }
            $resolved = Resolve-AvmBicepTestToken `
                -Content '{"name":"#_namePrefix_#","scope":"#_subscriptionId_#"}' `
                -SourcePath 'test.json' -Tokens $tokens
            $obj = $resolved | ConvertFrom-Json -AsHashtable
            $obj.name | Should -Be 'quote"slash\value'
            $obj.scope | Should -Be $S
            { Resolve-AvmBicepTestToken -Content '{"name":"#_missing_#"}' `
                    -SourcePath 'test.json' -Tokens $tokens } |
                Should -Throw -ExpectedMessage '*Unresolved*missing*'
        }
    }
}

Describe 'Bicep e2e example selection' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ('bicep-selection-' + [guid]::NewGuid().ToString('N'))
        $script:example = Join-Path $script:root 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $script:example -Force
        Set-Content -LiteralPath (Join-Path $script:root 'main.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:example 'main.test.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        $script:context = [pscustomobject]@{
            Kind = 'bicep-module'; Root = $script:root; Ecosystem = 'bicep'
        }
    }

    It 'discovers a root case and selects by name or relative path' {
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context } {
            param($C)
            $cases = @(Get-AvmBicepTestCase -Context $C)
            $cases.Count | Should -Be 1
            $cases[0].RelativePath | Should -Be 'tests/e2e/defaults/main.test.bicep'
            @(Select-AvmBicepTestCase -Cases $cases -Example 'defaults').Count | Should -Be 1
            @(Select-AvmBicepTestCase -Cases $cases -Example 'tests/e2e/defaults').Count |
                Should -Be 1
            @(Select-AvmBicepTestCase -Cases $cases `
                    -Example @('defaults', 'tests/e2e/defaults')).Count | Should -Be 1
        }
    }

    It 'excludes .e2eignore but refuses an explicit ignored selection' {
        Set-Content -LiteralPath (Join-Path $script:example '.e2eignore') `
            -Value 'pending' -Encoding utf8NoBOM
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context } {
            param($C)
            $cases = @(Get-AvmBicepTestCase -Context $C)
            $cases[0].Ignored | Should -BeTrue
            @(Select-AvmBicepTestCase -Cases $cases).Count | Should -Be 0
            { Select-AvmBicepTestCase -Cases $cases -Example defaults } |
                Should -Throw -ExpectedMessage '*opted out*'
            { Select-AvmBicepTestCase -Cases $cases -Example missing } |
                Should -Throw -ExpectedMessage '*Unknown*'
        }
    }

    It 'checks exact entrypoint casing before selection' {
        Rename-Item -LiteralPath (Join-Path $script:example 'main.test.bicep') `
            -NewName 'Main.test.bicep'
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context } {
            param($C)
            { Get-AvmBicepTestCase -Context $C } |
                Should -Throw -ExpectedMessage '*exact casing*'
        }
    }

    It 'reports ambiguous names across nested modules' {
        $nested = Join-Path $script:root 'child' 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $nested -Force
        Set-Content -LiteralPath (Join-Path $script:root 'child' 'main.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $nested 'main.test.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context } {
            param($C)
            @(Get-AvmBicepTestCase -Context $C).Count | Should -Be 1
            $cases = @(Get-AvmBicepTestCase -Context $C -Recurse)
            $cases.Count | Should -Be 2
            { Select-AvmBicepTestCase -Cases $cases -Example defaults } |
                Should -Throw -ExpectedMessage '*Ambiguous*'
            @(Select-AvmBicepTestCase -Cases $cases `
                    -Example 'child/tests/e2e/defaults').Count | Should -Be 1
        }
    }
}

Describe 'Bicep ARM template and parameter staging' {
    It 'classifies compiled ARM scope and writes only the temp destination (<Scope>)' -ForEach @(
        @{ Scope = 'group'; Name = 'deploymentTemplate' }
        @{ Scope = 'sub'; Name = 'subscriptionDeploymentTemplate' }
        @{ Scope = 'mg'; Name = 'managementGroupDeploymentTemplate' }
        @{ Scope = 'tenant'; Name = 'tenantDeploymentTemplate' }
    ) {
        $destination = Join-Path $TestDrive ('stage-' + $Scope + '.json')
        $schema = "https://schema.management.azure.com/schemas/2019-04-01/$Name.json#"
        InModuleScope 'Avm.Authoring' -Parameters @{
            D = $destination; S = $schema; Subscription = $script:subscription; Root = $TestDrive; Kind = $Scope
        } {
            param($D, $S, $Subscription, $Root, $Kind)
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = ('{"$schema":"' + $S + '","name":"#_namePrefix_#"}')
                    StdErr   = ''
                }
            }
            $map = Get-AvmBicepTestTokenMap -Root $Root `
                -SubscriptionId $Subscription -Tokens @{ namePrefix = 'avm' }
            $built = New-AvmBicepTestTemplate -SourcePath 'unchanged.bicep' `
                -DestinationPath $D -BicepPath 'fake-bicep' -Tokens $map
            $built.Scope | Should -Be $Kind
            $built.Template.name | Should -Be 'avm'
            ([IO.File]::ReadAllText($D) | ConvertFrom-Json -AsHashtable).name |
                Should -Be 'avm'
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'build' -and $ArgumentList[1] -eq '--stdout'
            }
        }
    }

    It 'creates an ARM parameter file and rejects conflicting sources' {
        $destination = Join-Path $TestDrive 'parameters-temp.json'
        $source = Join-Path $TestDrive 'parameters-source.json'
        Set-Content -LiteralPath $source `
            -Value '{"parameters":{"example":{"value":"#_namePrefix_#"}}}' -Encoding utf8NoBOM
        InModuleScope 'Avm.Authoring' -Parameters @{
            D = $destination; R = $TestDrive; S = $script:subscription
        } {
            param($D, $R, $S)
            $map = Get-AvmBicepTestTokenMap -Root $R -SubscriptionId $S `
                -Tokens @{ namePrefix = 'avm' }
            $path = New-AvmBicepTestParameterFile -Root $R -DestinationPath $D `
                -Tokens $map -ParameterFile 'parameters-source.json'
            $path | Should -Be $D
            ([IO.File]::ReadAllText($D) | ConvertFrom-Json -AsHashtable).parameters.example.value |
                Should -Be 'avm'
            { New-AvmBicepTestParameterFile -Root $R -DestinationPath $D `
                    -Tokens $map -ParameterFile 'parameters-source.json' `
                    -Parameters @{ example = 'avm' } } |
                Should -Throw -ExpectedMessage '*not both*'
            (New-AvmBicepTestParameterFile -Root $R -DestinationPath $D -Tokens $map) |
                Should -BeNullOrEmpty
        }
        (Get-Content -LiteralPath $source -Raw) | Should -Match '#_namePrefix_#'
    }

    It 'places ARM scope flags and parameter-file paths in separate argv entries' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
            }
            $null = Invoke-AvmBicepArmOperation -AzPath 'fake-az' -TemplatePath 'a file.json' `
                -Scope group -Operation WhatIf -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -DeploymentName 'avm-test' -WorkingDirectory '.' -ResourceGroupName 'test-group' `
                -ParameterPath 'private parameters.json'
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'deployment' -and
                $ArgumentList[1] -eq 'group' -and
                $ArgumentList[2] -eq 'what-if' -and
                $ArgumentList -contains 'a file.json' -and
                $ArgumentList -contains '@private parameters.json' -and
                $ArgumentList -contains '--no-prompt'
            }
            { Invoke-AvmBicepArmOperation -AzPath 'fake-az' -TemplatePath 'a.json' `
                    -Scope mg -Operation Validate -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                    -DeploymentName 'avm-test' -WorkingDirectory '.' -Location 'westus' } |
                Should -Throw -ExpectedMessage '*ManagementGroupId*'
        }
    }

    It 'uses supported Create flags for <Scope> deployments' -ForEach @(
        @{ Scope = 'group'; Mode = $true }
        @{ Scope = 'sub'; Mode = $false }
        @{ Scope = 'mg'; Mode = $true }
        @{ Scope = 'tenant'; Mode = $false }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{
            K = $Scope; ExpectMode = $Mode
        } {
            param($K, $ExpectMode)
            Mock Invoke-AvmProcess {
                $script:createArguments = [string[]]$ArgumentList
                [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
            }
            $null = Invoke-AvmBicepArmOperation -AzPath 'fake-az' `
                -TemplatePath 'case.json' -Scope $K -Operation Create `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -DeploymentName 'avm-test' -WorkingDirectory '.' -Location 'westus' `
                -ResourceGroupName 'test-group' -ManagementGroupId 'test-mg'
            $script:createArguments[2] | Should -Be 'create'
            ($script:createArguments -contains '--mode') | Should -Be $ExpectMode
            if ($ExpectMode) {
                $script:createArguments | Should -Contain 'Incremental'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1
        }
    }
}
