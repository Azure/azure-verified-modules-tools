#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $script:fixturePath = Join-Path $script:repoRoot `
        'tests' 'fixtures' 'bicep-scoped' 'route-table-defaults.6eb8e6ff.json'
    $script:pinnedTemplate = Get-Content -LiteralPath $script:fixturePath -Raw -Encoding utf8
    $script:subscription = '00000000-0000-0000-0000-000000000001'
    $script:tenant = '00000000-0000-0000-0000-000000000002'
    $script:runId = '0123456789abcdef0123456789abcdef'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep owned cross-group preflight' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ('owned-cross-group-' + [guid]::NewGuid().ToString('N'))
        $testDirectory = Join-Path $script:root 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        Set-Content -LiteralPath (Join-Path $script:root 'main.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        $script:source = Join-Path $testDirectory 'main.test.bicep'
        Set-Content -LiteralPath $script:source -Value 'param name string' -Encoding utf8NoBOM
        $script:state = [pscustomobject]@{
            TemplateJson = $script:pinnedTemplate
            Calls = [System.Collections.Generic.List[object]]::new()
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ State = $script:state } {
            param($State)
            $script:ownedGroupState = $State
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Path = 'fake-bicep'; Version = '0.47.16'; Source = 'stub' }
            }
            Mock Get-Command {
                [pscustomobject]@{ Source = 'fake-az' }
            } -ParameterFilter { $Name -eq 'az' }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $script:ownedGroupState.Calls.Add([pscustomobject]@{
                        FilePath = $FilePath
                        Arguments = [string[]]$ArgumentList
                    })
                if ($FilePath -eq 'fake-bicep') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = $script:ownedGroupState.TemplateJson
                        StdErr = ''
                    }
                }
                throw "Unexpected fake Azure call: $($ArgumentList -join ' ')"
            }
        }
    }

    It 'tags only the staged ARM group at Create while keeping source and nested module intact' {
        $destination = Join-Path $TestDrive 'staged-owned-group.json'
        $sourceHash = (Get-FileHash -LiteralPath $script:source -Algorithm SHA256).Hash
        $fixtureHash = (Get-FileHash -LiteralPath $script:fixturePath -Algorithm SHA256).Hash
        $built = InModuleScope 'Avm.Authoring' -Parameters @{
            Source = $script:source; Destination = $destination
            Root = $script:root; Subscription = $script:subscription
            Tenant = $script:tenant; RunId = $script:runId
        } {
            param($Source, $Destination, $Root, $Subscription, $Tenant, $RunId)
            $tokens = Get-AvmBicepTestTokenMap -Root $Root `
                -SubscriptionId $Subscription -TenantId $Tenant -RunId $RunId
            New-AvmBicepTestTemplate -SourcePath $Source -DestinationPath $Destination `
                -BicepPath 'fake-bicep' -Tokens $tokens -ScopedTokens $tokens `
                -RequireScopedTokens -OwnedGroupRunId $RunId -SourceRoot $Root -Confirm:$false
        }
        $built.Scope | Should -Be 'sub'
        $built.HasGroupDeployment | Should -BeTrue
        $stored = Get-Content -LiteralPath $destination -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable
        $stored.resources[0].tags['avm-e2e-run-id'] | Should -BeExactly $script:runId
        $stored.resources[0].name | Should -BeExactly $stored.resources[1].resourceGroup
        $stored.resources[1].properties.template.resources.routeTable.type |
            Should -BeExactly 'Microsoft.Network/routeTables'
        $stored.resources[1].properties.template.resources.routeTable_lock.type |
            Should -BeExactly 'Microsoft.Authorization/locks'
        $stored.parameters.namePrefix.defaultValue |
            Should -BeExactly ('avm' + $script:runId.Substring(0, 10))
        (Get-FileHash -LiteralPath $script:source -Algorithm SHA256).Hash |
            Should -BeExactly $sourceHash
        (Get-FileHash -LiteralPath $script:fixturePath -Algorithm SHA256).Hash |
            Should -BeExactly $fixtureHash
        @(Get-ChildItem -LiteralPath $script:root -Recurse -File -Filter '*.json').Count |
            Should -Be 0
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count |
            Should -Be 0
    }

    It 'rejects staging into the authored module directory before writing any JSON' {
        $destination = Join-Path $script:root 'tests' 'e2e' 'defaults' 'main.test.json'
        InModuleScope 'Avm.Authoring' -Parameters @{
            Source = $script:source; Destination = $destination
            Root = $script:root; Subscription = $script:subscription
            Tenant = $script:tenant; RunId = $script:runId
        } {
            param($Source, $Destination, $Root, $Subscription, $Tenant, $RunId)
            $tokens = Get-AvmBicepTestTokenMap -Root $Root `
                -SubscriptionId $Subscription -TenantId $Tenant -RunId $RunId
            { New-AvmBicepTestTemplate -SourcePath $Source -DestinationPath $Destination `
                    -BicepPath 'fake-bicep' -Tokens $tokens -ScopedTokens $tokens `
                    -RequireScopedTokens -OwnedGroupRunId $RunId -SourceRoot $Root -Confirm:$false } |
                Should -Throw -ExpectedMessage '*outside module source*'
        }
        Test-Path -LiteralPath $destination | Should -BeFalse
    }

    It 'refuses the complete pinned example before any fake Azure call' {
        { Invoke-AvmTestE2e -Path $script:root -SubscriptionId $script:subscription `
                -TenantId $script:tenant -Location 'westus' -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*cross-scope resource (scope)*'
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count |
            Should -Be 0
    }

    It 'refuses the reduced pinned template without durable recovery before any fake Azure call' {
        $reduced = $script:pinnedTemplate | ConvertFrom-Json -AsHashtable
        $nested = $reduced.resources[1].properties.template.resources
        $null = $nested.Remove('routeTable_lock')
        $null = $nested.Remove('routeTable_roleAssignments')
        $script:state.TemplateJson = $reduced | ConvertTo-Json -Depth 100 -Compress
        { Invoke-AvmTestE2e -Path $script:root -SubscriptionId $script:subscription `
                -TenantId $script:tenant -Location 'westus' -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*crash recovery and owned teardown*'
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count |
            Should -Be 0
    }

    It 'refuses an authored foreign ownership tag before any fake Azure call' {
        $foreign = $script:pinnedTemplate | ConvertFrom-Json -AsHashtable
        $foreign.resources[0].tags = @{ 'avm-e2e-run-id' = 'foreign-run' }
        $script:state.TemplateJson = $foreign | ConvertTo-Json -Depth 100 -Compress
        { Invoke-AvmTestE2e -Path $script:root -SubscriptionId $script:subscription `
                -TenantId $script:tenant -Location 'westus' -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*different group ownership tag*'
        @($script:state.Calls | Where-Object { $_.FilePath -eq 'fake-az' }).Count |
            Should -Be 0
    }
}
