#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTestCleanup' {
    It 'exports the cleanup command and routes avm test cleanup to it' {
        Get-Command Invoke-AvmTestCleanup -Module Avm.Authoring | Should -Not -BeNullOrEmpty
        InModuleScope Avm.Authoring {
            $entry = Get-AvmVerbRegistry | Where-Object { ($_.Path -join ' ') -eq 'test cleanup' }
            $entry.Cmdlet | Should -Be 'Invoke-AvmTestCleanup'
        }
    }

    It 'forwards explicit targets and unfinished work without requiring a module checkout' {
        InModuleScope Avm.Authoring {
            Mock Test-AvmModuleVersion {}
            Mock Invoke-AvmBicepCleanup {
                @{ Status = 'fail'; Cleaned = $false; Pending = @('/pending'); Issues = @(); StatePath = 'state.json' }
            }
            $result = Invoke-AvmTestCleanup -StatePath 'state.json' `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002' -SearchRetryLimit 1 -RemovalRetryLimit 2
            $result.Status | Should -Be 'fail'
            $result.CleanupPending | Should -Contain '/pending'
            $result.StatePath | Should -Be 'state.json'
            Should -Invoke Invoke-AvmBicepCleanup -Exactly 1 -ParameterFilter {
                $SubscriptionId -eq '00000000-0000-0000-0000-000000000001' -and
                $TenantId -eq '00000000-0000-0000-0000-000000000002' -and
                $SearchRetryLimit -eq 1 -and $RemovalRetryLimit -eq 2 -and -not $WhatIf
            }
        }
    }

    It 'passes WhatIf through to the state-only preview without approving deletion' {
        InModuleScope Avm.Authoring {
            Mock Test-AvmModuleVersion {}
            Mock Invoke-AvmBicepCleanup {
                @{ Status = 'skipped'; Cleaned = $false; Pending = @(); Issues = @(); StatePath = 'state.json' }
            }
            $result = Invoke-AvmTestCleanup -StatePath 'state.json' `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002' -WhatIf
            $result.Status | Should -Be 'skipped'
            Should -Invoke Invoke-AvmBicepCleanup -Exactly 1 -ParameterFilter { $WhatIf }
        }
    }
}
