#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:Invoke-AzRestMethod {
            [CmdletBinding()]
            param($Method, $Path)
            throw 'Unexpected Azure request.'
        }
        function script:New-AzResourceGroupDeployment {
            [CmdletBinding()]
            param($Name, $ResourceGroupName, $Mode, $Force, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt)
            throw 'Unexpected Azure deployment.'
        }
        function script:Test-AzResourceGroupDeployment {
            [CmdletBinding()]
            param($ResourceGroupName, $Mode, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt)
            throw 'Unexpected Azure validation.'
        }
        function script:New-AzSubscriptionDeployment {
            [CmdletBinding()]
            param($Name, $Location, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt)
            throw 'Unexpected Azure deployment.'
        }
        function script:New-AzManagementGroupDeployment {
            [CmdletBinding()]
            param($Name, $Location, $ManagementGroupId, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt)
            throw 'Unexpected Azure deployment.'
        }
        function script:New-AzTenantDeployment {
            [CmdletBinding()]
            param($Name, $Location, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt)
            throw 'Unexpected Azure deployment.'
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep native ARM operation' {
    It 'keeps authored parameter names and secure values inside TemplateParameterObject' {
        InModuleScope Avm.Authoring {
            Mock New-AzResourceGroupDeployment { @{ ProvisioningState = 'Succeeded' } }
            $password = [securestring]::new()
            $parameters = @{ Name = 'authored'; keys = @('one'); count = 0; password = $password }
            $null = Invoke-AvmBicepNativeArmOperation -Scope group -Operation Create -TemplatePath 'test.json' `
                -DeploymentName 'attempt' -MetadataLocation 'westus' -ResourceGroupName 'owned' -Parameters $parameters
            Should -Invoke New-AzResourceGroupDeployment -Exactly 1 -ParameterFilter {
                $Name -eq 'attempt' -and $ResourceGroupName -eq 'owned' -and $Mode -eq 'Incremental' -and
                $TemplateParameterObject['Name'] -eq 'authored' -and
                $TemplateParameterObject['count'] -eq 0 -and
                $TemplateParameterObject['password'] -is [securestring] -and $SkipTemplateParameterPrompt -and
                -not $Verbose -and -not $Debug
            }
        }
    }

    It 'routes higher scopes without adding unsupported mode or force flags: <Scope>' -ForEach @(
        @{ Scope = 'sub'; Command = 'New-AzSubscriptionDeployment' }
        @{ Scope = 'mg'; Command = 'New-AzManagementGroupDeployment' }
        @{ Scope = 'tenant'; Command = 'New-AzTenantDeployment' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Scope = $Scope; Command = $Command } {
            param($Scope, $Command)
            Mock $Command { @{ ProvisioningState = 'Succeeded' } }
            $null = Invoke-AvmBicepNativeArmOperation -Scope $Scope -Operation Create -TemplatePath 'test.json' `
                -DeploymentName 'attempt' -MetadataLocation 'westus' -ManagementGroupId 'test-mg'
            Should -Invoke $Command -Exactly 1 -ParameterFilter {
                $Name -eq 'attempt' -and $Location -eq 'westus' -and $SkipTemplateParameterPrompt
            }
        }
    }

    It 'retains structured validation errors without putting response messages in the public exception' {
        InModuleScope Avm.Authoring {
            Mock Test-AzResourceGroupDeployment {
                @{ Code = 'InvalidTemplateDeployment'; Details = @(@{
                            Code = 'AllocationFailed'; Message = 'Secret do-not-print capacity error in region.'
                        }) }
            }
            $errorRecord = $null
            try {
                Invoke-AvmBicepNativeArmOperation -Scope group -Operation Validate -TemplatePath 'test.json' `
                    -DeploymentName 'attempt' -MetadataLocation 'westus' -ResourceGroupName 'owned'
            }
            catch { $errorRecord = $_ }
            $errorRecord.FullyQualifiedErrorId | Should -BeLike 'AvmBicepTemplateValidationFailed*'
            $errorRecord.Exception.Message | Should -Not -Match 'do-not-print'
            (Test-AvmBicepRegionalValidationError -ErrorRecord $errorRecord) | Should -BeTrue
        }
    }

    It 'does not call Azure under WhatIf' {
        InModuleScope Avm.Authoring {
            Mock New-AzResourceGroupDeployment { throw 'Unexpected deployment.' }
            Invoke-AvmBicepNativeArmOperation -Scope group -Operation Create -TemplatePath 'test.json' `
                -DeploymentName 'attempt' -MetadataLocation 'westus' -ResourceGroupName 'owned' -WhatIf
            Should -Invoke New-AzResourceGroupDeployment -Exactly 0
        }
    }
}

Describe 'Bicep native deployment retries' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:state = @{
                subscriptionId = '00000000-0000-0000-0000-000000000001'
                runId = '00000000000000000000000000000010'
                deployments = @()
            }
            $script:inputOptions = @{
                Scope = 'sub'; TemplatePath = 'test.json'; MetadataLocation = 'westus'
                Parameters = @{ baseTime = '2026-10-02 12:34:56Z' }
            }
            $script:persisted = @()
            Mock Save-AvmBicepCleanupState {
                $script:persisted = @($State['deployments'] | ForEach-Object { $_['id'] + ':' + $_['status'] })
            }
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
        }
    }

    It 'persists exact attempted IDs before submission and retains a stable baseTime through confirmed-failure retries' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepNativeArmOperation {
                $script:persisted[-1] | Should -BeLike "*/$DeploymentName`:Attempted"
                $Parameters['baseTime'] | Should -Be '2026-10-02 12:34:56Z'
                $id = "/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/$DeploymentName"
                if ($DeploymentName -like '*-t1') { return @{ Id = $id; ProvisioningState = 'Failed' } }
                return @{ Id = $id; ProvisioningState = 'Succeeded'; Outputs = @{ resourceId = @{ value = 'id' } } }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
            $result.Status | Should -Be 'pass'
            $script:state.deployments.Count | Should -Be 2
            $script:state.deployments[0].status | Should -Be 'Failed'
            $script:state.deployments[1].status | Should -Be 'Succeeded'
            $result.Outputs['resourceId']['value'] | Should -Be 'id'
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 2
            Should -Invoke Start-Sleep -Exactly 1
        }
    }

    It 'retries exact preflight rejection and preserves every rejected attempt for discovery' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepNativeArmOperation {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "10:20:30 - Error: Code=InvalidTemplateDeployment; Message=The template deployment '$DeploymentName' is not valid according to the validation procedure. Resource reported preflight validation errors."),
                    'NativeDeploymentError', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
            $result.Status | Should -Be 'fail'
            $script:state.deployments.Count | Should -Be 3
            @($script:state.deployments | Where-Object { $_.preflightRejected -and $_.status -eq 'Rejected' }).Count |
                Should -Be 3
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 3
        }
    }

    It 'never resubmits an unknown outcome: <Failure>' -ForEach @(
        @{ Failure = 'timeout' }, @{ Failure = 'transport' }, @{ Failure = 'null' }
        @{ Failure = 'running' }, @{ Failure = 'unclassified exception' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Failure = $Failure } {
            param($Failure)
            Mock Invoke-AvmBicepNativeArmOperation {
                switch ($Failure) {
                    'timeout' { throw [System.TimeoutException]::new('Timed out.') }
                    'transport' { throw [System.Net.Http.HttpRequestException]::new('Transport failed.') }
                    'null' { return $null }
                    'running' {
                        return @{
                            Id = "/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/$DeploymentName"
                            ProvisioningState = 'Running'
                        }
                    }
                    default { throw [System.InvalidOperationException]::new('Unclassified.') }
                }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
            $result.Status | Should -Be 'fail'
            $result.Outcome | Should -Be 'Unknown'
            $script:state.deployments.Count | Should -Be 1
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'does not accept a terminal response without the exact attempted ID: <ResponseId> <Outcome>' -ForEach @(
        @{ ResponseId = $null; Outcome = 'Succeeded' }
        @{ ResponseId = '/another/deployment'; Outcome = 'Succeeded' }
        @{ ResponseId = $null; Outcome = 'Failed' }
        @{ ResponseId = '/another/deployment'; Outcome = 'Failed' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ ResponseId = $ResponseId; Outcome = $Outcome } {
            param($ResponseId, $Outcome)
            Mock Invoke-AvmBicepNativeArmOperation {
                [pscustomobject]@{ Id = $ResponseId; ProvisioningState = $Outcome }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
            $result.Status | Should -Be 'fail'
            $result.Outcome | Should -Be 'Unknown'
            $script:persisted[-1] | Should -BeLike '*:Unknown'
            $script:state.deployments.Count | Should -Be 1
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'persists cancellation as unknown and propagates it without another submission' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepNativeArmOperation { throw [System.OperationCanceledException]::new('Canceled.') }
            { New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions } |
                Should -Throw -ExpectedMessage '*Canceled*'
            $script:persisted[-1] | Should -BeLike '*:Unknown'
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
        }
    }
}

Describe 'Bicep native deployment cleanup readiness' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/attempt'
            $script:state = @{ deployments = @(@{ id = $script:id; status = 'Unknown'; preflightRejected = $false }) }
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
        }
    }

    It 'waits for a terminal outcome before permitting cleanup' {
        InModuleScope Avm.Authoring {
            $script:requests = 0
            Mock Invoke-AzRestMethod {
                $script:requests++
                $state = if ($script:requests -eq 1) { 'Running' } else { 'Failed' }
                @{ StatusCode = 200; Content = (@{ id = $script:id; properties = @{ provisioningState = $state } } | ConvertTo-Json) }
            }
            $result = Get-AvmBicepPendingDeployment -State $script:state -RetryLimit 2 -RetryInterval 0
            $result.Pending.Count | Should -Be 0
            $script:state.deployments[0].status | Should -Be 'Failed'
            Should -Invoke Invoke-AzRestMethod -Exactly 2
        }
    }

    It 'retains missing, running, malformed and unreadable deployments: <Condition>' -ForEach @(
        @{ Condition = 'missing' }, @{ Condition = 'running' }, @{ Condition = 'wrong ID' }, @{ Condition = 'forbidden' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Condition = $Condition } {
            param($Condition)
            Mock Invoke-AzRestMethod {
                switch ($Condition) {
                    'missing' { @{ StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}' } }
                    'running' {
                        @{ StatusCode = 200; Content = (@{ id = $script:id; properties = @{ provisioningState = 'Running' } } | ConvertTo-Json) }
                    }
                    'wrong ID' {
                        @{ StatusCode = 200; Content = '{"id":"/another/deployment","properties":{"provisioningState":"Succeeded"}}' }
                    }
                    default { @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' } }
                }
            }
            $result = Get-AvmBicepPendingDeployment -State $script:state -RetryLimit 1
            $result.Pending | Should -Contain $script:id
            $result.Issues.Count | Should -Be 1
            $script:state.deployments[0].status | Should -Be 'Unknown'
        }
    }
}
