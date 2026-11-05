#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:Get-AzContext { [CmdletBinding()] param() throw 'Unmocked context.' }
        function script:Set-AzContext {
            [CmdletBinding()] param($Context, $Subscription, $Tenant, $Scope) throw 'Unmocked context change.'
        }
        function script:Get-AzResource {
            [CmdletBinding()] param($ResourceGroupName) throw 'Unmocked resource listing.'
        }
    }
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep workflow cleanup provider containers' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:providerContainer = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage'
            $script:providerContext = @{
                Subscription = @{ Id = '00000000-0000-0000-0000-000000000003' }
                Tenant = @{ Id = '00000000-0000-0000-0000-000000000002' }
                Account = @{ Id = 'fixture-principal' }; Environment = @{ Name = 'AzureCloud' }
            }
            Mock Get-AzContext { $script:providerContext }
            Mock Set-AzContext {
                param($Context, $Subscription, $Tenant, $Scope)
                $Scope | Should -BeExactly 'Process'
                $script:providerContext = if ($null -ne $Context) { $Context } else {
                    @{
                        Subscription = @{ Id = $Subscription }; Tenant = @{ Id = $Tenant }
                        Account = @{ Id = 'fixture-principal' }; Environment = @{ Name = 'AzureCloud' }
                    }
                }
                return $script:providerContext
            }
            Mock Get-AzResource { throw 'Unexpected listing.' }
        }
    }

    It 'expands only an exact RG provider prefix in that subscription and restores the original context' {
        InModuleScope Avm.Authoring {
            Mock Get-AzResource {
                $ResourceGroupName | Should -BeExactly 'test'
                $script:providerContext.Subscription.Id | Should -Be '00000000-0000-0000-0000-000000000001'
                @(
                    @{ ResourceId = "$script:providerContainer/storageAccounts/one" }
                    @{ Id = "$script:providerContainer/storageAccounts/two" }
                    @{ Id = "$($script:providerContainer)Extra/storageAccounts/foreign" }
                    @{ Id = $script:providerContainer.Replace('/test/', '/test-other/') + '/storageAccounts/foreign' }
                    @{ Id = $script:providerContainer.Replace('000000000001', '000000000004') + '/storageAccounts/foreign' }
                )
            }
            $resources = @(Resolve-AvmBicepCleanupResource -ResourceId $script:providerContainer)
            $resources.Count | Should -Be 2
            @($resources.resourceId) | Should -Be @(
                "$script:providerContainer/storageAccounts/one", "$script:providerContainer/storageAccounts/two"
            )
            $script:providerContext.Subscription.Id | Should -Be '00000000-0000-0000-0000-000000000003'
            Should -Invoke Get-AzResource -Exactly 1 -ParameterFilter { $ResourceGroupName -ceq 'test' }
        }
    }

    It 'returns a complete resource ID without requesting a resource inventory' {
        InModuleScope Avm.Authoring {
            $id = "$script:providerContainer/storageAccounts/one"
            @(Resolve-AvmBicepCleanupResource -ResourceId $id)[0].resourceId | Should -BeExactly $id
            Should -Invoke Get-AzResource -Exactly 0
            Should -Invoke Set-AzContext -Exactly 0
        }
    }

    It 'does not broaden malformed containers into a subscription listing: <Id>' -ForEach @(
        @{ Id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Storage' }
        @{ Id = '/subscriptions/not-a-guid/resourceGroups/test/providers/Microsoft.Storage' }
        @{ Id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/../providers/Microsoft.Storage' }
        @{ Id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Id = $Id } {
            param($Id)
            { Resolve-AvmBicepCleanupResource -ResourceId $Id } | Should -Throw
            Should -Invoke Get-AzResource -Exactly 0
            Should -Invoke Set-AzContext -Exactly 0
        }
    }

    It 'fails on a missing or malformed returned ID instead of silently losing targets: <Kind>' -ForEach @(
        @{ Kind = 'missing' }, @{ Kind = 'incomplete' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Kind = $Kind } {
            param($Kind)
            $script:badProviderRecord = if ($Kind -eq 'missing') { @{ Name = 'one' } } else {
                @{ Id = "$script:providerContainer/storageAccounts" }
            }
            Mock Get-AzResource { $script:badProviderRecord }
            { Resolve-AvmBicepCleanupResource -ResourceId $script:providerContainer } | Should -Throw
            $script:providerContext.Subscription.Id | Should -Be '00000000-0000-0000-0000-000000000003'
        }
    }

    It 'accepts only a confirmed missing group as empty, never a permission failure' {
        InModuleScope Avm.Authoring {
            Mock Get-AzResource {
                throw [Net.Http.HttpRequestException]::new('Missing', $null, [Net.HttpStatusCode]::NotFound)
            }
            @(Resolve-AvmBicepCleanupResource -ResourceId $script:providerContainer).Count | Should -Be 0
            Mock Get-AzResource {
                throw [Net.Http.HttpRequestException]::new('Denied', $null, [Net.HttpStatusCode]::Forbidden)
            }
            { Resolve-AvmBicepCleanupResource -ResourceId $script:providerContainer } | Should -Throw -ExpectedMessage '*Denied*'
            $script:providerContext.Subscription.Id | Should -Be '00000000-0000-0000-0000-000000000003'
        }
    }

    It 'does not hide a failure to restore the caller context' {
        InModuleScope Avm.Authoring {
            Mock Get-AzResource {}
            Mock Set-AzContext { throw [InvalidOperationException]::new('Cannot restore context.') } `
                -ParameterFilter { $null -ne $Context }
            $failure = $null
            try { Resolve-AvmBicepCleanupResource -ResourceId $script:providerContainer } catch { $failure = $_ }
            $failure.FullyQualifiedErrorId | Should -BeLike 'AvmBicepContextRestoreFailed*'
        }
    }

    It 'retries canceled context selection and restoration without repeating the operation' {
        InModuleScope Avm.Authoring {
            $script:selections = 0
            $script:restorations = 0
            $script:executions = 0
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
            Mock Set-AzContext {
                if ($null -ne $Context) {
                    $script:restorations++
                    if ($script:restorations -lt 2) { throw [OperationCanceledException]::new('restore canceled') }
                    return $Context
                }
                $script:selections++
                if ($script:selections -lt 3) { throw [OperationCanceledException]::new('selection canceled') }
                @{
                    Subscription = @{ Id = $Subscription }; Tenant = @{ Id = $Tenant }
                    Account = @{ Id = 'fixture-principal' }; Environment = @{ Name = 'AzureCloud' }
                }
            }
            Invoke-AvmBicepAzureContext -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002' `
                -ScriptBlock { $script:executions++ }
            $script:selections | Should -Be 3
            $script:restorations | Should -Be 2
            $script:executions | Should -Be 1
            Should -Invoke Start-Sleep -Exactly 3
        }
    }

    It 'fails after bounded canceled context selection and restores the original context' {
        InModuleScope Avm.Authoring {
            $script:executed = $false
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
            Mock Set-AzContext {
                if ($null -ne $Context) { return $Context }
                throw [OperationCanceledException]::new('selection canceled')
            }
            { Invoke-AvmBicepAzureContext -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                    -TenantId '00000000-0000-0000-0000-000000000002' `
                    -ScriptBlock { $script:executed = $true } } | Should -Throw '*selection canceled*'
            $script:executed | Should -BeFalse
            Should -Invoke Set-AzContext -Exactly 3 -ParameterFilter { $null -ne $Subscription }
            Should -Invoke Set-AzContext -Exactly 1 -ParameterFilter { $null -ne $Context }
            Should -Invoke Start-Sleep -Exactly 2
        }
    }

    It 'reports exhausted context restoration as fatal' {
        InModuleScope Avm.Authoring {
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
            Mock Set-AzContext { throw [OperationCanceledException]::new('restore canceled') } `
                -ParameterFilter { $null -ne $Context }
            $failure = $null
            try { Resolve-AvmBicepCleanupResource -ResourceId $script:providerContainer } catch { $failure = $_ }
            $failure.FullyQualifiedErrorId | Should -BeLike 'AvmBicepContextRestoreFailed*'
            Should -Invoke Set-AzContext -Exactly 3 -ParameterFilter { $null -ne $Context }
            Should -Invoke Start-Sleep -Exactly 2
        }
    }
}
