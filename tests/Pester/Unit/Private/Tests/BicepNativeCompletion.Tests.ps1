#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:Get-AzContext { [CmdletBinding()] param() throw 'Unexpected Azure context lookup.' }
        function script:Invoke-AzRestMethod {
            [CmdletBinding()] param($Method, $Path) throw 'Unexpected Azure request.'
        }
    }
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep native cleanup case contract' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:caseInput = @{
                path = 'child/tests/e2e/defaults/main.test.bicep'; scope = 'sub'
                resourceGroupName = ''; managementGroupId = ''; metadataLocation = 'eastus'
                sourceHash = 'a' * 64; completionStarted = $false
            }
        }
    }

    It 'retains only case recovery fields at <Scope> scope' -ForEach @(
        @{ Scope = 'group' }, @{ Scope = 'sub' }, @{ Scope = 'mg' }, @{ Scope = 'tenant' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Scope = $Scope } {
            param($Scope)
            $script:caseInput.scope = $Scope
            if ($Scope -eq 'group') { $script:caseInput.resourceGroupName = 'owned-group' }
            if ($Scope -eq 'mg') { $script:caseInput.managementGroupId = 'existing-group' }
            $script:caseInput['parameters'] = @{ value = 'must-not-be-copied' }
            $result = ConvertTo-AvmBicepCleanupCase -Case $script:caseInput
            $result.psbase.Count | Should -Be 7
            $result['scope'] | Should -BeExactly $Scope
            $result['path'] | Should -BeExactly 'child/tests/e2e/defaults/main.test.bicep'
            $result.Contains('parameters') | Should -BeFalse
            $result['completionStarted'] | Should -BeFalse
            $script:caseInput.ContainsKey('parameters') | Should -BeTrue
        }
    }

    It 'rejects invalid case metadata: <Field> <Value>' -ForEach @(
        @{ Field = 'scope'; Value = 'SUB' }
        @{ Field = 'scope'; Value = 'unknown' }
        @{ Field = 'metadataLocation'; Value = 'East US' }
        @{ Field = 'metadataLocation'; Value = '' }
        @{ Field = 'sourceHash'; Value = 'not-a-hash' }
        @{ Field = 'sourceHash'; Value = ('A' * 64) }
        @{ Field = 'completionStarted'; Value = 'false' }
        @{ Field = 'path'; Value = '../tests/e2e/defaults/main.test.bicep' }
        @{ Field = 'path'; Value = '/tests/e2e/defaults/main.test.bicep' }
        @{ Field = 'path'; Value = 'tests\e2e\defaults\main.test.bicep' }
        @{ Field = 'path'; Value = 'tests/e2e/../defaults/main.test.bicep' }
        @{ Field = 'path'; Value = 'tests/e2e//defaults/main.test.bicep' }
        @{ Field = 'path'; Value = 'tests/e2e/defaults/Main.test.bicep' }
        @{ Field = 'path'; Value = "tests/e2e/`n/main.test.bicep" }
        @{ Field = 'path'; Value = 'tests/e2e/defaults/main.test.bicep:stream' }
        @{ Field = 'resourceGroupName'; Value = 'foreign-group' }
        @{ Field = 'managementGroupId'; Value = 'foreign-group' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Field = $Field; Value = $Value } {
            param($Field, $Value)
            $script:caseInput[$Field] = $Value
            { ConvertTo-AvmBicepCleanupCase -Case $script:caseInput } | Should -Throw
        }
    }

    It 'rejects unsafe execution-container names at <Scope> scope: <Name>' -ForEach @(
        @{ Scope = 'group'; Name = '' }, @{ Scope = 'group'; Name = 'trailing.' }
        @{ Scope = 'group'; Name = '/foreign/group' }, @{ Scope = 'mg'; Name = '' }
        @{ Scope = 'mg'; Name = '..' }, @{ Scope = 'mg'; Name = 'trailing.' }
        @{ Scope = 'mg'; Name = '/providers/Microsoft.Management/managementGroups/foreign' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Scope = $Scope; Name = $Name } {
            param($Scope, $Name)
            $script:caseInput.scope = $Scope
            $field = if ($Scope -eq 'group') { 'resourceGroupName' } else { 'managementGroupId' }
            $script:caseInput[$field] = $Name
            { ConvertTo-AvmBicepCleanupCase -Case $script:caseInput } | Should -Throw
        }
    }
}

Describe 'Bicep native completion decisions' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:completionState = @{
                status = 'Pending'; subscriptionId = '00000000-0000-0000-0000-000000000001'
                tenantId = '00000000-0000-0000-0000-000000000002'; environment = 'AzureCloud'
                runId = '00000000000000000000000000000010'
                case = @{
                    path = 'tests/e2e/defaults/main.test.bicep'; scope = 'sub'
                    sourceHash = 'a' * 64; completionStarted = $false
                    managementGroupId = ''; resourceGroupName = ''; metadataLocation = 'eastus'
                }
                deployments = @(@{
                        id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/avm-e2e-00000000000000000000000000000010-t1'
                        status = 'Succeeded'
                    })
                ownedResourceGroups = @()
            }
            $script:completionInput = @{
                Item = [pscustomobject]@{
                    Case = [pscustomobject]@{
                        RelativePath = 'tests/e2e/defaults/main.test.bicep'
                        RelativeDirectory = 'tests/e2e/defaults'; ModuleRoot = 'unused-module-root'
                    }
                    Scope = 'sub'; AssertionFiles = @('never-opened.Tests.ps1')
                }
                StatePath = 'never-opened.json'
                SubscriptionId = [guid]'00000000-0000-0000-0000-000000000001'
                TenantId = [guid]'00000000-0000-0000-0000-000000000002'
                RepositoryRoot = 'unused-repository-root'; AzPath = 'never-run-az'
            }
            $script:completionCalls = [Collections.Generic.List[string]]::new()
            Mock Read-AvmBicepCleanupState { $script:completionState }
            Mock Save-AvmBicepCleanupState {}
            Mock Get-AvmBicepTestSourceHash { 'a' * 64 }
            Mock Invoke-AvmBicepAzureContext { & $ScriptBlock }
            Mock Get-AzContext { @{ Environment = @{ Name = 'AzureCloud' } } }
            Mock Assert-AvmBicepAzureIdentity {}
            Mock Get-AvmBicepPendingDeployment { [pscustomobject]@{ Pending = @(); Issues = @() } }
            Mock Invoke-AzRestMethod {
                @{ StatusCode = 200; Content = (@{
                            id = $script:completionState.deployments[0].id
                            properties = @{ provisioningState = 'Succeeded'; outputs = @{} }
                        } | ConvertTo-Json -Depth 8) }
            }
            Mock Invoke-AvmBicepTestE2eAssertion {
                $script:completionState.case.completionStarted | Should -BeTrue
                $script:completionCalls.Add('assertions')
                [pscustomobject]@{ Status = 'pass' }
            }
            Mock Invoke-AvmBicepE2ePostHook {
                $script:completionCalls.Add('post')
                [pscustomobject]@{ Status = 'pass' }
            }
            Mock Invoke-AvmBicepCleanup {
                $script:completionCalls.Add('cleanup')
                [pscustomobject]@{ Cleaned = $true; Pending = @(); Issues = @() }
            }
        }
    }

    It 'records completion before same-process assertions, then runs post and cleanup in order' {
        InModuleScope Avm.Authoring {
            $result = Complete-AvmBicepTestCase @script:completionInput
            $result.Status | Should -Be 'pass'
            $script:completionCalls.ToArray() | Should -Be @('assertions', 'post', 'cleanup')
            Should -Invoke Save-AvmBicepCleanupState -Exactly 2
            Should -Invoke Invoke-AvmBicepTestE2eAssertion -Exactly 1 -ParameterFilter { $InProcess }
            Should -Invoke Invoke-AvmBicepE2ePostHook -Exactly 1 -ParameterFilter { $InProcess }
            $result.CleanupPending.Count | Should -Be 0
        }
    }

    It 'retains resources without post processing when explicitly requested' {
        InModuleScope Avm.Authoring {
            $result = Complete-AvmBicepTestCase @script:completionInput -KeepResources
            $result.Status | Should -Be 'pass'
            $result.CleanupDeferred | Should -BeTrue
            $script:completionCalls.ToArray() | Should -Be @('assertions')
            Should -Invoke Invoke-AvmBicepCleanup -Exactly 0
        }
    }

    It 'refuses replay, changed source or mismatched target before Azure: <Change>' -ForEach @(
        @{ Change = 'complete' }, @{ Change = 'started' }, @{ Change = 'source' }
        @{ Change = 'case' }, @{ Change = 'scope' }, @{ Change = 'subscription' }, @{ Change = 'tenant' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Change = $Change } {
            param($Change)
            switch ($Change) {
                complete { $script:completionState.status = 'Complete' }
                started { $script:completionState.case.completionStarted = $true }
                source { Mock Get-AvmBicepTestSourceHash { 'b' * 64 } }
                case { $script:completionState.case.path = 'tests/e2e/foreign/main.test.bicep' }
                scope { $script:completionState.case.scope = 'tenant' }
                subscription { $script:completionState.subscriptionId = '00000000-0000-0000-0000-000000000099' }
                tenant { $script:completionState.tenantId = '00000000-0000-0000-0000-000000000099' }
            }
            { Complete-AvmBicepTestCase @script:completionInput } | Should -Throw
            Should -Invoke Invoke-AvmBicepAzureContext -Exactly 0
            Should -Invoke Save-AvmBicepCleanupState -Exactly 0
        }
    }

    It 'defers unconfirmed deployment outcomes without marking authored work as started' {
        InModuleScope Avm.Authoring {
            Mock Get-AvmBicepPendingDeployment {
                [pscustomobject]@{
                    Pending = @($script:completionState.deployments[0].id)
                    Issues = @([pscustomobject]@{ Message = 'Still running.' })
                }
            }
            $result = Complete-AvmBicepTestCase @script:completionInput
            $result.Status | Should -Be 'fail'
            $result.CleanupDeferred | Should -BeTrue
            $result.CleanupPending.Count | Should -Be 1
            $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-deployment-pending'
            $script:completionState.case.completionStarted | Should -BeFalse
            $script:completionCalls.Count | Should -Be 0
        }
    }

    It 'does not mistake deployment failure for an assertion pass' {
        InModuleScope Avm.Authoring {
            $script:completionState.deployments[0].status = 'Failed'
            $result = Complete-AvmBicepTestCase @script:completionInput
            $result.Status | Should -Be 'fail'
            $result.AssertionResults.Count | Should -Be 0
            $script:completionCalls.ToArray() | Should -Be @('post', 'cleanup')
        }
    }

    It 'keeps ordinary cleanup after an assertion or post-hook exception: <Phase>' -ForEach @(
        @{ Phase = 'assertions' }, @{ Phase = 'post' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Phase = $Phase } {
            param($Phase)
            if ($Phase -eq 'assertions') { Mock Invoke-AvmBicepTestE2eAssertion { throw [InvalidOperationException]::new('authored failure') } }
            else { Mock Invoke-AvmBicepE2ePostHook { throw [InvalidOperationException]::new('authored failure') } }
            $result = Complete-AvmBicepTestCase @script:completionInput
            $result.Status | Should -Be 'fail'
            $result.Issues.Count | Should -Be 1
            Should -Invoke Invoke-AvmBicepCleanup -Exactly 1
        }
    }

    It 'propagates cancellation without starting cleanup in the interrupted host: <Phase>' -ForEach @(
        @{ Phase = 'assertions' }, @{ Phase = 'post' }, @{ Phase = 'cleanup' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Phase = $Phase } {
            param($Phase)
            switch ($Phase) {
                assertions { Mock Invoke-AvmBicepTestE2eAssertion { throw [OperationCanceledException]::new('cancelled') } }
                post { Mock Invoke-AvmBicepE2ePostHook { throw [OperationCanceledException]::new('cancelled') } }
                cleanup { Mock Invoke-AvmBicepCleanup { throw [OperationCanceledException]::new('cancelled') } }
            }
            { Complete-AvmBicepTestCase @script:completionInput } | Should -Throw -ExceptionType ([OperationCanceledException])
            $script:completionState.case.completionStarted | Should -BeTrue
            if ($Phase -ne 'cleanup') { Should -Invoke Invoke-AvmBicepCleanup -Exactly 0 }
        }
    }

    It 'returns recorded pending targets when cleanup cannot start' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepCleanup { throw [IO.IOException]::new('state unavailable') }
            $result = Complete-AvmBicepTestCase @script:completionInput
            $result.Status | Should -Be 'fail'
            $result.CleanupPending | Should -Be @($script:completionState.deployments[0].id)
            $result.Issues[0].Code | Should -Be 'avm.bicep.e2e-cleanup-failed'
        }
    }

    It 'refuses an unexpected cloud without running authored work' {
        InModuleScope Avm.Authoring {
            Mock Get-AzContext { @{ Environment = @{ Name = 'AzureUSGovernment' } } }
            { Complete-AvmBicepTestCase @script:completionInput } | Should -Throw -ExpectedMessage '*different Azure cloud*'
            $script:completionCalls.Count | Should -Be 0
        }
    }

    It 'does not perform context selection or persist completion under WhatIf' {
        InModuleScope Avm.Authoring {
            $result = Complete-AvmBicepTestCase @script:completionInput -WhatIf
            $result.Status | Should -Be 'skipped'
            Should -Invoke Invoke-AvmBicepAzureContext -Exactly 0
            Should -Invoke Save-AvmBicepCleanupState -Exactly 0
        }
    }
}
