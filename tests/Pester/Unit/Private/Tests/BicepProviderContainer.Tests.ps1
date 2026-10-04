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
}
