#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepNativeWorkflow.ps1')
    $script:fixturePath = Join-Path $script:repoRoot `
        'tests' 'fixtures' 'bicep-scoped' 'route-table-defaults.6eb8e6ff.json'
    $script:pinnedTemplate = Get-Content -LiteralPath $script:fixturePath -Raw -Encoding utf8
    $script:runId = '0123456789abcdef0123456789abcdef'
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: Bicep native pinned-template workflow' -Tag Component {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:options = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
        $script:fixture.Compiled = $script:pinnedTemplate
        $script:fixture.Nested = $true
        $script:fixture.NestedResourceType = 'Microsoft.Network/routeTables'
        $script:fixture.NestedExtensions = @(
            'Microsoft.Authorization/locks/test-lock'
            'Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000007'
        )
        $script:source = Join-Path $script:fixture.Directory 'main.test.bicep'
    }
    AfterEach { Remove-NativeBicepWorkflowFixture -Fixture $script:fixture }

    It 'keeps the optional private ownership staging outside authored files' {
        $destination = Join-Path $TestDrive 'staged-owned-group.json'
        $sourceHash = (Get-FileHash -LiteralPath $script:source -Algorithm SHA256).Hash
        $fixtureHash = (Get-FileHash -LiteralPath $script:fixturePath -Algorithm SHA256).Hash
        $built = InModuleScope Avm.Authoring -Parameters @{
            Source = $script:source; Destination = $destination
            Root = $script:fixture.Root; Subscription = $script:options.SubscriptionId
            Tenant = $script:options.TenantId; RunId = $script:runId
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
        $stored = Get-Content -LiteralPath $destination -Raw | ConvertFrom-Json -AsHashtable
        $stored.resources[0].tags['avm-e2e-run-id'] | Should -BeExactly $script:runId
        $stored.resources[0].name | Should -BeExactly $stored.resources[1].resourceGroup
        $stored.resources[1].properties.template.resources.routeTable_lock.type |
            Should -BeExactly 'Microsoft.Authorization/locks'
        (Get-FileHash -LiteralPath $script:source -Algorithm SHA256).Hash | Should -BeExactly $sourceHash
        (Get-FileHash -LiteralPath $script:fixturePath -Algorithm SHA256).Hash | Should -BeExactly $fixtureHash
        @($script:fixture.Calls) | Should -Be @('compile')
    }

    It 'rejects private ownership staging into the authored directory before writing JSON' {
        $destination = Join-Path $script:fixture.Directory 'main.test.json'
        InModuleScope Avm.Authoring -Parameters @{
            Source = $script:source; Destination = $destination
            Root = $script:fixture.Root; Subscription = $script:options.SubscriptionId
            Tenant = $script:options.TenantId; RunId = $script:runId
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

    It 'accepts the complete pinned route-table template including its locks and assignments' {
        $fixtureHash = (Get-FileHash -LiteralPath $script:fixturePath -Algorithm SHA256).Hash
        $sourceHash = (Get-FileHash -LiteralPath $script:source -Algorithm SHA256).Hash
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $script:fixture.NativeInputs[0].Scope | Should -Be 'sub'
        $template = $script:fixture.NativeInputs[0].Content | ConvertFrom-Json -AsHashtable
        $nested = $template.resources[1].properties.template.resources
        $nested.routeTable.type | Should -BeExactly 'Microsoft.Network/routeTables'
        $nested.routeTable_lock.type | Should -BeExactly 'Microsoft.Authorization/locks'
        $nested.routeTable_roleAssignments.type | Should -BeExactly 'Microsoft.Authorization/roleAssignments'
        foreach ($extension in $script:fixture.NestedExtensions) {
            $script:fixture.Calls | Should -Contain ("remove:$($script:fixture.CreatedId)/providers/$extension")
        }
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.status | Should -Be 'Complete'
        $stored.resources.Count | Should -Be 4
        @($stored.resources | Where-Object { -not $_.removed -or -not $_.postProcessed }).Count | Should -Be 0
        (Get-FileHash -LiteralPath $script:fixturePath -Algorithm SHA256).Hash | Should -BeExactly $fixtureHash
        (Get-FileHash -LiteralPath $script:source -Algorithm SHA256).Hash | Should -BeExactly $sourceHash
    }

    It 'accepts the complete pinned management-group role-definition template' {
        $path = Join-Path $script:repoRoot 'tests' 'fixtures' 'bicep-scoped' 'role-definition-mg-default.6eb8e6ff.json'
        $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $script:fixture.Compiled = Get-Content -LiteralPath $path -Raw
        $script:fixture.Nested = $false
        $script:fixture.RootResourceType = 'Microsoft.Authorization/roleDefinitions'
        $script:options.ManagementGroupId = 'test-management-group'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $script:fixture.NativeInputs[0].Scope | Should -Be 'mg'
        $script:fixture.Calls | Should -Contain ('remove:' + $script:fixture.CreatedId)
        $script:fixture.Calls | Should -Not -Contain 'remove:/providers/Microsoft.Management/managementGroups/test-management-group'
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    It 'preserves authored nested-group tags rather than imposing runner ownership on the template' {
        $template = $script:pinnedTemplate | ConvertFrom-Json -AsHashtable
        $template.resources[0].tags = @{ 'avm-e2e-run-id' = 'source-authored-tag'; purpose = 'registry-test' }
        $script:fixture.Compiled = $template | ConvertTo-Json -Depth 100 -Compress
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $staged = $script:fixture.NativeInputs[0].Content | ConvertFrom-Json -AsHashtable
        $staged.resources[0].tags['avm-e2e-run-id'] | Should -BeExactly 'source-authored-tag'
        $staged.resources[0].tags.purpose | Should -BeExactly 'registry-test'
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.ownedResourceGroups.Count | Should -Be 0
        $stored.resources.Count | Should -Be 4
    }
}
