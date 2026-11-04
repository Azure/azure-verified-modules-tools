#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:Invoke-AzRestMethod {
            [CmdletBinding()] param($Method, $Path, $DefaultProfile)
            throw 'Unexpected Azure request.'
        }
        function script:New-AzSubscriptionDeployment {
            [CmdletBinding(SupportsShouldProcess)]
            param($Name, $Location, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt, $DefaultProfile)
            throw 'Unexpected Azure deployment.'
        }
        foreach ($scope in @('ResourceGroup', 'Subscription', 'ManagementGroup', 'Tenant')) {
            Set-Item -Path "function:script:Get-Az${scope}DeploymentWhatIfResult" -Value {
                [CmdletBinding()] param($Name, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt,
                    $ResultFormat, $Location, $ResourceGroupName, $Mode, $ManagementGroupId, $DefaultProfile)
                throw 'Unexpected What-If request.'
            }
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep deployment progress logging' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:messages = [Collections.Generic.List[string]]::new()
            $script:id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/root'
            Mock Write-AvmLog { $script:messages.Add($Message) }
        }

    }

    It 'routes resource-ID-only What-If for <Scope>' -ForEach @(
        @{ Scope = 'group'; Command = 'Get-AzResourceGroupDeploymentWhatIfResult' }
        @{ Scope = 'sub'; Command = 'Get-AzSubscriptionDeploymentWhatIfResult' }
        @{ Scope = 'mg'; Command = 'Get-AzManagementGroupDeploymentWhatIfResult' }
        @{ Scope = 'tenant'; Command = 'Get-AzTenantDeploymentWhatIfResult' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Scope = $Scope; Command = $Command } {
            param($Scope, $Command)
            Mock $Command {
                [pscustomobject]@{
                    PSTypeName = 'Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.Deployments.PSWhatIfOperationResult'
                    Changes = @([pscustomobject]@{
                            PSTypeName = 'Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.Deployments.PSWhatIfChange'
                            FullyQualifiedResourceId = '/subscriptions/example/providers/Microsoft.KeyVault/vaults/test'
                            ChangeType = 'Create'
                        })
                }
            }
            $options = @{
                Scope = $Scope; DeploymentName = 'test'; TemplatePath = 'fixture.json'; MetadataLocation = 'westus'
                Parameters = @{ password = 'hidden' }; ResourceGroupName = 'group'; ManagementGroupId = 'mg'
            }
            Write-AvmBicepWhatIf -DeploymentInput $options
            Should -Invoke $Command -Exactly 1 -ParameterFilter { $ResultFormat -eq 'ResourceIdOnly' }
            ($script:messages -join ' ') | Should -Match 'Create /subscriptions/example/providers/Microsoft.KeyVault/vaults/test'
            ($script:messages -join ' ') | Should -Not -Match 'hidden'
        }
    }

    It 'reports and redacts What-If errors without suppressing cancellation' {
        InModuleScope Avm.Authoring {
            $options = @{ Scope = 'sub'; DeploymentName = 'test'; TemplatePath = 'fixture'; MetadataLocation = 'westus'; Parameters = @{} }
            Mock Get-AzSubscriptionDeploymentWhatIfResult { throw 'secret=example-secret' }
            Write-AvmBicepWhatIf -DeploymentInput $options
            ($script:messages -join ' ') | Should -Match 'What-If could not'
            ($script:messages -join ' ') | Should -Not -Match 'example-secret'
            Mock Get-AzSubscriptionDeploymentWhatIfResult { throw [OperationCanceledException]::new('cancelled') }
            { Write-AvmBicepWhatIf -DeploymentInput $options } | Should -Throw
        }
    }

    It 'reports each state change once and follows only same-subscription nested deployments' {
        InModuleScope Avm.Authoring {
            $child = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Resources/deployments/nested'
            $foreign = '/subscriptions/00000000-0000-0000-0000-000000000002/providers/Microsoft.Resources/deployments/foreign'
            $script:state = 'Running'
            Mock Invoke-AzRestMethod {
                $body = if ($Path -like "$child/operations?*") {
                    @{ value = @(@{ properties = @{ provisioningState = $script:state; timestamp = '2026-01-01T00:00:00Z'; duration = 'PT5S'
                                    targetResource = @{ id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.KeyVault/vaults/vault'; resourceType = 'Microsoft.KeyVault/vaults'; resourceName = 'vault' } } }) }
                }
                else {
                    @{ value = @(
                            @{ properties = @{ provisioningState = 'Running'; targetResource = @{ id = $child; resourceType = 'Microsoft.Resources/deployments'; resourceName = 'nested' } } },
                            @{ properties = @{ provisioningState = 'Running'; targetResource = @{ id = $foreign; resourceType = 'Microsoft.Resources/deployments'; resourceName = 'foreign' } } }
                        ) }
                }
                @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 20 -Compress) }
            }
            $observed = @{}
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            $script:state = 'Succeeded'
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            @($script:messages | Where-Object { $_ -match 'name=vault' }).Count | Should -Be 2
            ($script:messages -join ' ') | Should -Match 'type=Microsoft.KeyVault/vaults name=vault state=Succeeded duration=PT5S'
            Should -Invoke Invoke-AzRestMethod -Exactly 0 -ParameterFilter { $Path -like "$foreign/*" }
            Should -Invoke Invoke-AzRestMethod -Exactly 3 -ParameterFilter { $Path -like "$child/*" }
        }
    }

    It 'reads every same-path page and reports a foreign pagination link without following it' {
        InModuleScope Avm.Authoring {
            $path = $script:id + '/operations'
            Mock Invoke-AzRestMethod {
                $body = if ($Path -like '*page=2') {
                    @{ value = @(); nextLink = '/subscriptions/other/providers/Microsoft.Resources/deployments/wrong/operations?page=3' }
                }
                else {
                    @{ value = @(); nextLink = "$path`?page=2" }
                }
                @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 20 -Compress) }
            }
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed @{}
            Should -Invoke Invoke-AzRestMethod -Exactly 2
            ($script:messages -join ' ') | Should -Match 'progress is incomplete'
        }
    }

    It 'prints ARM output values and never exposes an unexpectedly returned secure value' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {
                $body = @{
                    id = $script:id; name = 'root'; properties = @{
                        provisioningState = 'Succeeded'; duration = 'PT2M'; correlationId = 'correlation'
                        outputs = @{ endpoint = @{ type = 'String'; value = 'https://example.test' }; count = @{ type = 'Int'; value = 0 } }
                    }
                }
                @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 20 -Compress) }
            }
            Write-AvmBicepDeploymentSummary -DeploymentId $script:id -Scope sub -Location westus -Observed @{}
            $text = $script:messages -join ' '
            $text | Should -Match 'name=root'
            $text | Should -Match 'state=Succeeded'
            $text | Should -Match 'endpoint \(String\): "https://example.test"'
            $text | Should -Match 'count \(Int\): 0'
            $script:messages.Clear()
            Mock Invoke-AzRestMethod {
                $body = @{ id = $script:id; properties = @{ outputs = @{ secure = @{ type = 'SecureString'; value = 'hidden-fixture-value' } } } }
                @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 20 -Compress) }
            }
            Write-AvmBicepDeploymentSummary -DeploymentId $script:id -Scope sub -Location westus -Observed @{}
            ($script:messages -join ' ') | Should -Not -Match 'hidden-fixture-value'
            ($script:messages -join ' ') | Should -Match 'unexpected value'
        }
    }
}

Describe 'Bicep asynchronous deployment submission' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:state = @{
                subscriptionId = '00000000-0000-0000-0000-000000000001'
                runId = '00000000000000000000000000000010'
                deployments = @()
            }
            $script:options = @{
                Scope = 'sub'; TemplatePath = 'fixture.json'; MetadataLocation = 'westus'; Parameters = @{}
            }
            Mock Get-AzContext { @{ Tenant = @{ Id = '00000000-0000-0000-0000-000000000002' } } }
            Mock Save-AvmBicepCleanupState {}
            Mock Write-AvmBicepWhatIf {}
            Mock Write-AvmBicepDeploymentProgress {}
            Mock Write-AvmBicepDeploymentSummary {}
            Mock Write-AvmBicepDeploymentDiagnostic { '' }
            Mock Test-AvmBicepNestedDeploymentReadFailure { $false }
        }
    }

    It 'keeps the recorded identity and result when an asynchronous job succeeds' {
        InModuleScope Avm.Authoring {
            Mock Start-AvmBicepNativeDeploymentJob {
                $id = "/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/$($DeploymentInput.DeploymentName)"
                Start-ThreadJob -ArgumentList $id -ScriptBlock {
                    param($id)
                    @{ Id = $id; ProvisioningState = 'Succeeded'; Outputs = @{} }
                }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                -DeploymentInput $script:options -ShowProgress
            $result.Status | Should -BeExactly 'pass'
            $script:state.deployments[0].status | Should -BeExactly 'Succeeded'
            Should -Invoke Start-AvmBicepNativeDeploymentJob -Exactly 1 -ParameterFilter {
                $DeploymentInput.DefaultProfile.Tenant.Id -eq '00000000-0000-0000-0000-000000000002'
            }
            Should -Invoke Write-AvmBicepDeploymentProgress -Times 1
            Should -Invoke Write-AvmBicepDeploymentSummary -Exactly 1
        }
    }

    It 'does not record a deployment if What-If stops before submission' {
        InModuleScope Avm.Authoring {
            Mock Write-AvmBicepWhatIf { throw [OperationCanceledException]::new('What-If stopped.') }
            Mock Start-AvmBicepNativeDeploymentJob { throw 'Deployment must not be submitted.' }
            { New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                    -DeploymentInput $script:options -ShowProgress } | Should -Throw '*What-If stopped*'
            $script:state.deployments.Count | Should -Be 0
            $pending = Get-AvmBicepPendingDeployment -State $script:state -RetryLimit 1 -RetryInterval 0
            $pending.Pending.Count | Should -Be 0
            Should -Invoke Save-AvmBicepCleanupState -Exactly 0
            Should -Invoke Start-AvmBicepNativeDeploymentJob -Exactly 0
        }

    }

    It 'retains a failed in-place deployment when What-If stops before resubmission' {
        InModuleScope Avm.Authoring {
            $id = "/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/avm-e2e-$($script:state.runId)-t1"
            $script:state.deployments = @(@{ id = $id; status = 'Failed'; preflightRejected = $false })
            Mock Write-AvmBicepWhatIf { throw [OperationCanceledException]::new('What-If stopped.') }
            Mock Start-AvmBicepNativeDeploymentJob { throw 'Deployment must not be submitted.' }
            { New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                    -DeploymentInput $script:options -Mode InPlace -ShowProgress } | Should -Throw '*What-If stopped*'
            $script:state.deployments[0].status | Should -BeExactly 'Failed'
            Should -Invoke Save-AvmBicepCleanupState -Exactly 0
            Should -Invoke Start-AvmBicepNativeDeploymentJob -Exactly 0
        }
    }

    It 'preserves job errors without reporting a successful deployment or resubmitting' {
        InModuleScope Avm.Authoring {
            Mock Start-AvmBicepNativeDeploymentJob {
                Start-ThreadJob -ScriptBlock { throw [InvalidOperationException]::new('Azure submission failed') }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                -DeploymentInput $script:options -ShowProgress
            $result.Status | Should -BeExactly 'fail'
            $result.ErrorRecord.Exception.Message | Should -Match 'Azure submission failed'
            $script:state.deployments[0].status | Should -BeExactly 'Unknown'
            Should -Invoke Start-AvmBicepNativeDeploymentJob -Exactly 1
            Should -Invoke Write-AvmBicepDeploymentDiagnostic -Exactly 1
        }
    }

    It 'keeps cancellation terminal for a stopped Azure job' {
        InModuleScope Avm.Authoring {
            Mock Start-AvmBicepNativeDeploymentJob {
                $job = Start-ThreadJob -ScriptBlock { Start-Sleep -Seconds 30 }
                while ($job.State -eq 'NotStarted') { Start-Sleep -Milliseconds 20 }
                Stop-Job -Job $job
                $job
            }
            $caught = $null
            try {
                $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                    -DeploymentInput $script:options -ShowProgress
            }
            catch { $caught = $_ }
            if ($null -eq $caught) {
                throw "Expected cancellation; got $($result.ErrorKind): $($result.ErrorRecord.Exception.Message)"
            }
            Should -Invoke Start-AvmBicepNativeDeploymentJob -Exactly 1
            Should -Invoke Write-AvmBicepDeploymentDiagnostic -Exactly 0
        }
    }
}

Describe 'Bicep submission with mocked Azure commands' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:state = @{
                subscriptionId = '00000000-0000-0000-0000-000000000001'
                runId = '00000000000000000000000000000010'
                deployments = @()
            }
            $script:options = @{
                Scope = 'sub'; TemplatePath = 'fixture.json'; MetadataLocation = 'westus'; Parameters = @{}
            }
            Mock Get-AzContext { @{ Tenant = @{ Id = '00000000-0000-0000-0000-000000000002' } } }
            Mock Save-AvmBicepCleanupState {}
            Mock Write-AvmBicepDeploymentProgress {}
            Mock Write-AvmBicepDeploymentSummary {}
            Mock Start-AvmBicepNativeDeploymentJob {
                $response = Invoke-AvmBicepNativeArmOperation @DeploymentInput -Operation Create -Confirm:$false
                Start-ThreadJob -ScriptBlock { param($Deployment) $Deployment } -ArgumentList (, $response)
            }
        }

    }

    It 'continues to the real submission wrapper after a What-If timeout' {
        InModuleScope Avm.Authoring {
            Mock Get-AzSubscriptionDeploymentWhatIfResult { throw [TimeoutException]::new('What-If timed out') }
            Mock New-AzSubscriptionDeployment {
                $id = "/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/$Name"
                @{ Id = $id; ProvisioningState = 'Succeeded'; Outputs = @{} }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                -DeploymentInput $script:options -ShowProgress
            $result.Status | Should -BeExactly 'pass'
            Should -Invoke Get-AzSubscriptionDeploymentWhatIfResult -Exactly 1 -ParameterFilter {
                $ResultFormat -eq 'ResourceIdOnly'
            }
            Should -Invoke New-AzSubscriptionDeployment -Exactly 1 -ParameterFilter {
                $DefaultProfile.Tenant.Id -eq '00000000-0000-0000-0000-000000000002'
            }
        }
    }

    It 'does not record or submit a deployment when Azure cancels What-If' {
        InModuleScope Avm.Authoring {
            Mock Get-AzSubscriptionDeploymentWhatIfResult { throw [OperationCanceledException]::new('cancelled') }
            Mock New-AzSubscriptionDeployment { throw 'Deployment must not be submitted.' }
            { New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                    -DeploymentInput $script:options -ShowProgress } | Should -Throw '*cancelled*'
            $script:state.deployments.Count | Should -Be 0
            Should -Invoke New-AzSubscriptionDeployment -Exactly 0
        }
    }
}
