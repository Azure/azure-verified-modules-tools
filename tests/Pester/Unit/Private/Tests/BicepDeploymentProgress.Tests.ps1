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
            Mock Start-Sleep {}
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
            ($script:messages -join ' ') | Should -Match 'Plan: 1 to create, 0 to change, 0 to delete\.'
            ($script:messages -join ' ') | Should -Not -Match 'hidden'
        }
    }

    It 'counts What-If creates, changes and deletes without counting unchanged resources' {
        InModuleScope Avm.Authoring {
            Mock Get-AzSubscriptionDeploymentWhatIfResult {
                @{ Changes = @('Create', 'Modify', 'Deploy', 'Delete', 'NoChange') | ForEach-Object {
                        @{ FullyQualifiedResourceId = "/subscriptions/example/$_"; ChangeType = $_ }
                    } }
            }
            $options = @{ Scope = 'sub'; DeploymentName = 'test'; TemplatePath = 'fixture'; MetadataLocation = 'westus'; Parameters = @{} }
            Write-AvmBicepWhatIf -DeploymentInput $options
            ($script:messages -join ' ') | Should -Match 'Plan: 1 to create, 2 to change, 1 to delete\.'
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

    It 'renders deployment identity and elapsed time without key-value dumps' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {
                @{ StatusCode = 200; Content = (@{
                            id = $script:id; name = 'root'; properties = @{
                                provisioningState = 'Succeeded'; duration = 'PT1M26S'
                                correlationId = '12345678-0000-0000-0000-000000000000'; outputs = @{}
                            }
                        } | ConvertTo-Json -Depth 10 -Compress) }
            }
            Write-AvmBicepDeploymentSummary -DeploymentId $script:id -Scope sub -Location westus -Observed @{}
            ($script:messages -join ' ') | Should -Match 'Deployment root succeeded after 1m26s\.'
            ($script:messages -join ' ') | Should -Match ([regex]::Escape($script:id))
            ($script:messages -join ' ') | Should -Match 'Scope: sub\. Location: westus\. Correlation ID: 12345678-0000-0000-0000-000000000000\.'
            ($script:messages -join ' ') | Should -Not -Match 'name=|id=|state=|duration=|PT1M26S'
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
            @($script:messages | Where-Object { $_ -match '^vault \(Microsoft.KeyVault/vaults\)' }).Count | Should -Be 2
            ($script:messages -join ' ') | Should -Match 'vault \(Microsoft.KeyVault/vaults\): Creating\.\.\.'
            ($script:messages -join ' ') | Should -Match 'vault \(Microsoft.KeyVault/vaults\): Created after 5s'
            ($script:messages -join ' ') | Should -Not -Match 'state=|duration=|PT5S'
            Should -Invoke Invoke-AzRestMethod -Exactly 0 -ParameterFilter { $Path -like "$foreign/*" }
            Should -Invoke Invoke-AzRestMethod -Exactly 3 -ParameterFilter { $Path -like "$child/*" }
        }
    }

    It 'treats only an initial DeploymentNotFound as a single waiting message' {
        InModuleScope Avm.Authoring {
            $script:stage = 'waiting'
            Mock Invoke-AzRestMethod {
                if ($script:stage -eq 'waiting') {
                    @{ StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}' }
                }
                else {
                    @{ StatusCode = 200; Content = '{"value":[]}' }
                }
            }
            $observed = @{}
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            @($script:messages | Where-Object { $_ -eq 'Waiting for the deployment to start.' }).Count | Should -Be 1
            ($script:messages -join ' ') | Should -Not -Match 'progress is incomplete'
            $script:stage = 'started'
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            $script:stage = 'waiting'
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            ($script:messages -join ' ') | Should -Match 'progress is incomplete.*DeploymentNotFound'
        }
    }

    It 'keeps polling the root when a nested deployment is not yet visible' {
        InModuleScope Avm.Authoring {
            $child = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Resources/deployments/nested'
            $script:childReady = $false
            Mock Invoke-AzRestMethod {
                if ($Path -like "$child/operations?*") {
                    if (-not $script:childReady) {
                        return @{ StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}' }
                    }
                    return @{ StatusCode = 200; Content = '{"value":[]}' }
                }
                $body = @{ value = @(@{ properties = @{ provisioningState = 'Running'; targetResource = @{
                                    id = $child; resourceType = 'Microsoft.Resources/deployments'; resourceName = 'nested'
                                } } }) }
                @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 10 -Compress) }
            }
            $observed = @{}
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            $script:childReady = $true
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            Should -Invoke Invoke-AzRestMethod -Exactly 2 -ParameterFilter { $Path -like "$child/operations?*" }
            Should -Invoke Invoke-AzRestMethod -Exactly 2 -ParameterFilter { $Path -like "$script:id/operations?*" }
            ($script:messages -join ' ') | Should -Not -Match 'progress is incomplete'
        }
    }

    It 'does not suppress a nested 404 with <Case>' -ForEach @(
        @{ Case = 'another error'; Body = '{"error":{"code":"ResourceNotFound"}}' }
        @{ Case = 'additional error details'; Body = '{"error":{"code":"DeploymentNotFound","details":[{"code":"AuthorizationFailed"}]}}' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Body = $Body } {
            param($Body)
            $child = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Resources/deployments/nested'
            Mock Invoke-AzRestMethod {
                if ($Path -like "$child/operations?*") {
                    return @{ StatusCode = 404; Content = $Body }
                }
                $body = @{ value = @(@{ properties = @{ provisioningState = 'Running'; targetResource = @{
                                    id = $child; resourceType = 'Microsoft.Resources/deployments'; resourceName = 'nested'
                                } } }) }
                @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 10 -Compress) }
            }
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed @{}
            ($script:messages -join ' ') | Should -Match 'progress is incomplete.*HTTP 404'
        }
    }

    It 'switches to deduplicated root status on operation 403 in <Form>' -ForEach @(
        @{ Form = 'response' }, @{ Form = 'exception' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Form = $Form } {
            param($Form)
            $script:rootState = 'Running'
            $profile = @{ Tenant = @{ Id = 'original' } }
            Mock Invoke-AzRestMethod {
                if ($Path -like '*/operations?*') {
                    if ($Form -eq 'exception') {
                        throw [Net.Http.HttpRequestException]::new('Forbidden.', $null, [Net.HttpStatusCode]::Forbidden)
                    }
                    return @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
                }
                $body = @{ id = $script:id; properties = @{ provisioningState = $script:rootState } }
                @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Compress) }
            }
            $observed = @{}
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed -DefaultProfile $profile
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed -DefaultProfile $profile
            $script:rootState = 'Succeeded'
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed -DefaultProfile $profile
            $expectedOperationsReads = if ($Form -eq 'response') { 12 } else { 1 }
            Should -Invoke Invoke-AzRestMethod -Exactly $expectedOperationsReads -ParameterFilter { $Path -like '*/operations?*' }
            Should -Invoke Invoke-AzRestMethod -Exactly 3 -ParameterFilter {
                $Path -ceq "$($script:id)?api-version=2021-04-01" -and
                [object]::ReferenceEquals($DefaultProfile, $profile)
            }
            @($script:messages | Where-Object { $_ -match 'operations are unavailable' }).Count | Should -Be 1
            @($script:messages | Where-Object { $_ -eq 'Deployment root: Running.' }).Count | Should -Be 1
            @($script:messages | Where-Object { $_ -eq 'Deployment root: Succeeded.' }).Count | Should -Be 1
        }
    }

    It 'does not trust a malformed root progress response after operations 403' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {
                if ($Path -like '*/operations?*') {
                    return @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
                }
                @{ StatusCode = 200; Content = '{"id":"/wrong","properties":{"provisioningState":"Succeeded"}}' }
            }
            $observed = @{}
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            @($script:messages | Where-Object { $_ -match 'Root deployment progress is incomplete' }).Count | Should -Be 1
            ($script:messages -join ' ') | Should -Not -Match 'Deployment root: Succeeded'
        }
    }

    It 'retries a canceled progress request and skips an exhausted poll without partial results' {
        InModuleScope Avm.Authoring {
            $script:requestCount = 0
            Mock Start-Sleep {}
            Mock Invoke-AzRestMethod {
                $script:requestCount++
                if ($script:requestCount -lt 3) { throw [OperationCanceledException]::new('request canceled') }
                @{ StatusCode = 200; Content = '{"value":[]}' }
            }
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed @{}
            Should -Invoke Invoke-AzRestMethod -Exactly 3
            Should -Invoke Start-Sleep -Exactly 2
            ($script:messages -join ' ') | Should -Not -Match 'progress is incomplete'

            $script:requestCount = 0
            $script:messages.Clear()
            Mock Invoke-AzRestMethod {
                $script:requestCount++
                if ($script:requestCount -eq 1) {
                    $body = @{
                        value = @(@{ properties = @{ provisioningState = 'Running'; targetResource = @{
                                            id = '/subscriptions/example/providers/Microsoft.KeyVault/vaults/one'
                                            resourceType = 'Microsoft.KeyVault/vaults'; resourceName = 'one'
                                        } } })
                        nextLink = "$script:id/operations?page=2"
                    }
                    return @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 10 -Compress) }
                }
                throw [OperationCanceledException]::new('request canceled')
            }
            $observed = @{}
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            $script:requestCount | Should -Be 4
            ($script:messages -join ' ') | Should -Match 'Deployment progress is incomplete'
            ($script:messages -join ' ') | Should -Not -Match 'one \(Microsoft.KeyVault/vaults\)'
            @($observed.Keys | Where-Object { $_ -like 'resource:*' }).Count | Should -Be 0
        }
    }

    It 'does not suppress an ambiguous cancellation with another inner failure' {
        InModuleScope Avm.Authoring {
            Mock Start-Sleep {}
            Mock Invoke-AzRestMethod {
                throw [OperationCanceledException]::new('cancelled', [InvalidOperationException]::new('another failure'))
            }
            { Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed @{} } | Should -Throw
            Should -Invoke Invoke-AzRestMethod -Exactly 1
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'orders and deduplicates nested resource observations without replaying older states' {
        InModuleScope Avm.Authoring {
            $child = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Resources/deployments/nested'
            $vault = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.KeyVault/vaults/vault'
            $script:stage = 1
            Mock Invoke-AzRestMethod {
                $body = if ($Path -like "$child/operations?*") {
                    $state = if ($script:stage -in @(1, 3)) { 'Running' } else { 'Succeeded' }
                    $time = if ($script:stage -ge 3) { '2026-01-01T00:00:03Z' } else { '2026-01-01T00:00:01Z' }
                    @{ value = @(@{ operationId = 'nested-operation'; properties = @{
                                    provisioningState = $state; timestamp = $time; duration = 'PT1M2S'
                                    targetResource = @{ id = $vault; resourceType = 'Microsoft.KeyVault/vaults'; resourceName = 'vault' }
                                } }) }
                }
                else {
                    @{ value = @(
                            @{ properties = @{ provisioningState = 'Running'; timestamp = '2026-01-01T00:00:02Z'
                                    targetResource = @{ id = $child; resourceType = 'Microsoft.Resources/deployments'; resourceName = 'nested' } } },
                            @{ operationId = 'old-operation'; properties = @{
                                    provisioningState = 'Succeeded'; timestamp = '2026-01-01T00:00:00Z'; duration = 'PT10S'
                                    targetResource = @{ id = $vault; resourceType = 'Microsoft.KeyVault/vaults'; resourceName = 'vault' }
                                } }
                        ) }
                }
                @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 20 -Compress) }
            }
            $observed = @{}
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            $script:messages[0] | Should -BeExactly 'vault (Microsoft.KeyVault/vaults): Creating...'
            $script:stage = 2
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            $script:stage = 3
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            $script:stage = 4
            Write-AvmBicepDeploymentProgress -DeploymentId $script:id -Observed $observed
            @($script:messages | Where-Object { $_ -like 'vault (*' }).Count | Should -Be 2
            ($script:messages -join ' ') | Should -Match 'vault \(Microsoft.KeyVault/vaults\): Created after 62s'
            @($observed.Keys | Where-Object { $_ -eq ('resource:' + $vault.ToLowerInvariant()) }).Count | Should -Be 1
            Mock Invoke-AzRestMethod {
                @{ StatusCode = 200; Content = (@{
                            id = $script:id; name = 'root'; properties = @{ outputs = @{} }
                        } | ConvertTo-Json -Depth 10 -Compress) }
            }
            $script:messages.Clear()
            Write-AvmBicepDeploymentSummary -DeploymentId $script:id -Scope sub -Location westus -Observed $observed
            @($script:messages | Where-Object { $_ -match 'Microsoft.KeyVault/vaults vault' }).Count | Should -Be 1
            ($script:messages -join ' ') | Should -Match 'No outputs\.'
        }
    }

    It 'prints each assertion result and reports absent assertions' {
        InModuleScope Avm.Authoring {
            $item = [pscustomobject]@{
                Case = [pscustomobject]@{ RelativeDirectory = 'case'; RelativePath = 'case/main.test.bicep'; Path = 'case/main.test.bicep' }
                AssertionFiles = @()
            }
            $issues = [Collections.Generic.List[object]]::new()
            $empty = Invoke-AvmBicepTestE2eAssertion -Item $item -DeploymentName 'fixture' `
                -DeploymentOutput '' -RepositoryRoot '.' -Issues $issues
            $empty.Status | Should -Be 'not-present'
            ($script:messages -join ' ') | Should -Match 'No post-deployment tests found\.'
            $script:messages.Clear()
            $item.AssertionFiles = @('assert.Tests.ps1')
            Mock Invoke-AvmBicepPesterSuite {
                @{ Total = 2; Passed = 1; Failed = 1; Skipped = 0; Inconclusive = 0; Filtered = 0; Issues = @()
                    Tests = @(@{ Name = 'checks one'; Result = 'Passed' }, @{ Name = 'checks two'; Result = 'Failed' }) }
            }
            $result = Invoke-AvmBicepTestE2eAssertion -Item $item -DeploymentName 'fixture' `
                -DeploymentOutput '{"properties":{"outputs":{}}}' -RepositoryRoot '.' -Issues $issues
            $result.Status | Should -Be 'fail'
            ($script:messages -join ' ') | Should -Match "checks one.*Passed"
            ($script:messages -join ' ') | Should -Match "checks two.*Failed"
            $script:messages.Clear()
            $issues.Clear()
            Mock Invoke-AvmBicepPesterSuite {
                @{ Total = 0; Passed = 0; Failed = 0; Skipped = 0; Inconclusive = 0; Filtered = 0; Issues = @(); Tests = @() }
            }
            $result = Invoke-AvmBicepTestE2eAssertion -Item $item -DeploymentName 'fixture' `
                -DeploymentOutput '{"properties":{"outputs":{}}}' -RepositoryRoot '.' -Issues $issues
            $result.Status | Should -Be 'fail'
            ($script:messages -join ' ') | Should -Match 'No post-deployment tests found\.'
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
            $text | Should -Match 'Deployment root succeeded after 2m0s\.'
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
            Mock Get-AvmBicepAzModuleManifest { @() }
        }
    }

    It 'keeps the recorded identity and result when an asynchronous job succeeds' {
        InModuleScope Avm.Authoring {
            Mock Start-AvmBicepNativeDeploymentJob {
                $SubmissionState.Invoked = $true
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
                $SubmissionState.Invoked = $true
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

    It 'records a failed job initialization as not submitted without polling cleanup' {
        InModuleScope Avm.Authoring {
            Mock Start-AvmBicepNativeDeploymentJob {
                Start-ThreadJob -ScriptBlock { throw [InvalidOperationException]::new('Azure module import failed') }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                -DeploymentInput $script:options -ShowProgress -ClassifyRetry
            $result.Outcome | Should -BeExactly 'NotSubmitted'
            $result.ErrorRecord.Exception.Message | Should -Match 'Azure module import failed'
            $script:state.deployments[0].status | Should -BeExactly 'NotSubmitted'
            $pending = Get-AvmBicepPendingDeployment -State $script:state -RetryLimit 1 -RetryInterval 0
            $pending.Pending.Count | Should -Be 0
            Should -Invoke Write-AvmBicepDeploymentDiagnostic -Exactly 1 -ParameterFilter { -not $ReadDeployment }
            Should -Invoke Write-AvmBicepDeploymentSummary -Exactly 0
        }
    }

    It 'does not observe a transport failure before the deployment cmdlet is invoked' {
        InModuleScope Avm.Authoring {
            Mock Start-AvmBicepNativeDeploymentJob {
                Start-ThreadJob -ScriptBlock { throw [Net.Http.HttpRequestException]::new('Import transport failure.') }
            }
            Mock Wait-AvmBicepNativeDeployment { throw 'Unexpected status observation.' }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                -DeploymentInput $script:options -ShowProgress -ClassifyRetry
            $result.Outcome | Should -BeExactly 'NotSubmitted'
            Should -Invoke Wait-AvmBicepNativeDeployment -Exactly 0
            Should -Invoke Start-AvmBicepNativeDeploymentJob -Exactly 1
        }
    }

    It 'observes typed transport failure from a submitted thread job without resubmitting' {
        InModuleScope Avm.Authoring {
            Mock Start-AvmBicepNativeDeploymentJob {
                $SubmissionState.Invoked = $true
                Start-ThreadJob -ScriptBlock {
                    $failure = [Net.Http.HttpRequestException]::new('Sending the request failed.', [IO.IOException]::new('Connection reset.'))
                    Write-Error -Exception $failure -ErrorAction Stop
                }
            }
            Mock Wait-AvmBicepNativeDeployment { @{ State = 'Succeeded'; Outputs = @{} } }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                -DeploymentInput $script:options -ShowProgress -ClassifyRetry
            $result.Outcome | Should -BeExactly 'Succeeded'
            Should -Invoke Wait-AvmBicepNativeDeployment -Exactly 1 -ParameterFilter {
                $DeploymentId -ceq $result.DeploymentId -and
                $DefaultProfile.Tenant.Id -ceq '00000000-0000-0000-0000-000000000002'
            }
            Should -Invoke Start-AvmBicepNativeDeploymentJob -Exactly 1
        }
    }

    It 'observes the exact root after a message-only 404 for an observed nested deployment' {
        InModuleScope Avm.Authoring {
            $child = "/subscriptions/$($script:state.subscriptionId)/resourceGroups/test/providers/Microsoft.Resources/deployments/module"
            Mock Get-AzContext {
                @{ Tenant = @{ Id = '00000000-0000-0000-0000-000000000002' }; Subscription = @{ Id = $script:state.subscriptionId } }
            }
            Mock Test-AvmBicepNestedDeploymentReadFailure { $false }
            Mock Write-AvmBicepDeploymentProgress {
                $Observed['resource:' + $child] = @{ Id = $child; Type = 'Microsoft.Resources/deployments' }
            }
            Mock Start-AvmBicepNativeDeploymentJob {
                $SubmissionState.Invoked = $true
                Start-ThreadJob -ScriptBlock {
                    Write-Error -Message "Deployment 'module' could not be found. StatusCode: 404 ReasonPhrase: Not Found OperationID : 977df3b0-c3a3-4d11-aeef-ec13e22668a1" -ErrorAction Stop
                }
            }
            Mock Wait-AvmBicepNativeDeployment { @{ State = 'Succeeded'; Outputs = @{} } }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                -DeploymentInput $script:options -ShowProgress -ClassifyRetry
            $result.Outcome | Should -BeExactly 'Succeeded'
            Should -Invoke Wait-AvmBicepNativeDeployment -Exactly 1 -ParameterFilter {
                $DeploymentId -ceq $result.DeploymentId -and $DefaultProfile.Subscription.Id -ceq $script:state.subscriptionId
            }
            Should -Invoke Start-AvmBicepNativeDeploymentJob -Exactly 1
        }
    }

    It 'preserves an earlier failed deployment when in-place initialization fails' {
        InModuleScope Avm.Authoring {
            $id = "/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/avm-e2e-$($script:state.runId)-t1"
            $script:state.deployments = @(@{ id = $id; status = 'Failed'; preflightRejected = $false })
            Mock Start-AvmBicepNativeDeploymentJob {
                Start-ThreadJob -ScriptBlock { throw [InvalidOperationException]::new('Azure module import failed') }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                -DeploymentInput $script:options -Mode InPlace -ShowProgress -ClassifyRetry
            $result.Outcome | Should -BeExactly 'Failed'
            $result.RetryMode | Should -BeExactly ''
            $script:state.deployments[0].status | Should -BeExactly 'Failed'
        }
    }

    It 'keeps cancellation terminal for a stopped Azure job' {
        InModuleScope Avm.Authoring {
            Mock Start-AvmBicepNativeDeploymentJob {
                $SubmissionState.Invoked = $true
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

Describe 'Bicep asynchronous deployment with canceled progress' {
    It 'reports the real job result when progress reads repeatedly cancel: <Outcome>' -ForEach @(
        @{ Outcome = 'Succeeded' }, @{ Outcome = 'Failed' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Outcome = $Outcome } {
            param($Outcome)
            $script:state = @{
                subscriptionId = '00000000-0000-0000-0000-000000000001'
                runId = '00000000000000000000000000000010'; deployments = @()
            }
            $options = @{ Scope = 'sub'; TemplatePath = 'fixture.json'; MetadataLocation = 'westus'; Parameters = @{} }
            Mock Get-AzContext { @{ Tenant = @{ Id = '00000000-0000-0000-0000-000000000002' } } }
            Mock Save-AvmBicepCleanupState {}
            Mock Write-AvmBicepWhatIf {}
            Mock Write-AvmBicepDeploymentSummary {}
            Mock Write-AvmBicepDeploymentDiagnostic { '' }
            Mock Test-AvmBicepNestedDeploymentReadFailure { $false }
            Mock Get-AvmBicepAzModuleManifest { @() }
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
            Mock Invoke-AzRestMethod { throw [OperationCanceledException]::new('progress read canceled') }
            $script:expectedOutcome = $Outcome
            Mock Start-AvmBicepNativeDeploymentJob {
                $SubmissionState.Invoked = $true
                $id = "/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/$($DeploymentInput.DeploymentName)"
                Start-ThreadJob -ArgumentList $id, $script:expectedOutcome -ScriptBlock {
                    param($id, $outcome)
                    if ($outcome -eq 'Failed') { throw [InvalidOperationException]::new('Azure submission failed') }
                    @{ Id = $id; ProvisioningState = 'Succeeded'; Outputs = @{} }
                }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'unused' `
                -DeploymentInput $options -ShowProgress
            if ($Outcome -eq 'Succeeded') {
                $result.Status | Should -BeExactly 'pass'
                $script:state.deployments[0].status | Should -BeExactly 'Succeeded'
            }
            else {
                $result.Status | Should -BeExactly 'fail'
                $result.ErrorRecord.Exception.Message | Should -Match 'Azure submission failed'
            }
            Should -Invoke Invoke-AzRestMethod -Times 3
            Should -Invoke Start-AvmBicepNativeDeploymentJob -Exactly 1
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
            Mock Get-AvmBicepAzModuleManifest { @() }
            Mock Start-AvmBicepNativeDeploymentJob {
                $response = Invoke-AvmBicepNativeArmOperation @DeploymentInput -Operation Create `
                    -SubmissionState $SubmissionState -Confirm:$false
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
