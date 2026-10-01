#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:tenant = '00000000-0000-4000-8000-000000001001'
    $script:admin = '00000000-0000-4000-8000-000000001002'
    $script:persistent = '00000000-0000-4000-8000-000000001003'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep BAMI test subscription pool selection' {
    BeforeEach {
        $script:pool = @(for ($number = 1; $number -le 28; $number++) {
                [ordered]@{
                    name = "test-$number"
                    id   = ('00000000-0000-4000-8000-{0:d12}' -f $number)
                }
            })
        $script:poolJson = ConvertTo-Json -InputObject $script:pool -Compress -Depth 4
    }

    It 'selects a uniform-index candidate from all 28 entries without a cloud call' {
        InModuleScope 'Avm.Authoring' -Parameters @{
            Json = $script:poolJson; T = $script:tenant
            A = $script:admin; P = $script:persistent
        } {
            param($Json, $T, $A, $P)
            Mock Get-AvmBicepTestPoolIndex { 27 }
            Mock Invoke-AvmProcess { throw 'No cloud calls permitted during selection.' }
            $selected = Select-AvmBicepTestPoolSubscription -PoolJson $Json `
                -TenantId $T -AdminSubscriptionId $A -PersistentSubscriptionId $P
            $selected.Name | Should -BeExactly 'test-28'
            $selected.SubscriptionId | Should -BeExactly '00000000-0000-4000-8000-000000000028'
            $selected.TenantId | Should -BeExactly $T
            Should -Invoke Get-AvmBicepTestPoolIndex -Exactly 1 -ParameterFilter { $Count -eq 28 }
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }

    It 'uses a cryptographically generated in-range index' {
        InModuleScope 'Avm.Authoring' {
            $indices = @(1..100 | ForEach-Object { Get-AvmBicepTestPoolIndex -Count 28 })
            $indices.Count | Should -Be 100
            @($indices | Where-Object { $_ -lt 0 -or $_ -ge 28 }).Count | Should -Be 0
        }
    }

    It 'rejects malformed or unsafe pool input before choosing <Case>' -ForEach @(
        @{ Case = 'malformed JSON' }
        @{ Case = 'scalar JSON' }
        @{ Case = 'object JSON' }
        @{ Case = 'short pool' }
        @{ Case = 'long pool' }
        @{ Case = 'null entry' }
        @{ Case = 'extra property' }
        @{ Case = 'missing property' }
        @{ Case = 'wrong property casing' }
        @{ Case = 'duplicate property' }
        @{ Case = 'non-string name' }
        @{ Case = 'non-string ID' }
        @{ Case = 'empty name' }
        @{ Case = 'padded name' }
        @{ Case = 'control character in name' }
        @{ Case = 'duplicate name with different casing' }
        @{ Case = 'malformed ID' }
        @{ Case = 'empty GUID' }
        @{ Case = 'duplicate ID with different casing' }
        @{ Case = 'Admin subscription in pool' }
        @{ Case = 'Persistent subscription in pool' }
        @{ Case = 'tenant ID in pool' }
    ) {
        $entries = $script:pool
        $json = $script:poolJson
        switch ($Case) {
            'malformed JSON' { $json = '[{"name":' }
            'scalar JSON' { $json = '"not a pool"' }
            'object JSON' { $json = '{"name":"test"}' }
            'short pool' { $entries = @($entries[0..26]) }
            'long pool' { $entries += @{ name = 'test-29'; id = '00000000-0000-4000-8000-000000000029' } }
            'null entry' { $entries[0] = $null }
            'extra property' { $entries[0].Add('extra', 'value') }
            'missing property' { $entries[0].Remove('name') }
            'wrong property casing' { $entries[0].Remove('name'); $entries[0].Add('Name', 'test-1') }
            'duplicate property' {
                $json = $json.Replace('"name":"test-1"', '"name":"test-1","name":"test-1"')
            }
            'non-string name' { $entries[0].name = 17 }
            'non-string ID' { $entries[0].id = 17 }
            'empty name' { $entries[0].name = '' }
            'padded name' { $entries[0].name = ' test-1 ' }
            'control character in name' { $entries[0].name = "test-1`n" }
            'duplicate name with different casing' { $entries[1].name = 'TEST-1' }
            'malformed ID' { $entries[0].id = 'not-an-id' }
            'empty GUID' { $entries[0].id = [guid]::Empty.ToString('D') }
            'duplicate ID with different casing' {
                $entries[0].id = '00000000-0000-4000-8000-00000000aabc'
                $entries[1].id = $entries[0].id.ToUpperInvariant()
            }
            'Admin subscription in pool' { $entries[0].id = $script:admin }
            'Persistent subscription in pool' { $entries[0].id = $script:persistent }
            'tenant ID in pool' { $entries[0].id = $script:tenant }
        }
        if ($Case -notin @('malformed JSON', 'scalar JSON', 'object JSON', 'duplicate property')) {
            $json = ConvertTo-Json -InputObject $entries -Compress -Depth 4
        }

        InModuleScope 'Avm.Authoring' -Parameters @{
            Json = $json; T = $script:tenant; A = $script:admin; P = $script:persistent
        } {
            param($Json, $T, $A, $P)
            Mock Get-AvmBicepTestPoolIndex { throw 'Invalid pool reached random selection.' }
            { Select-AvmBicepTestPoolSubscription -PoolJson $Json `
                    -TenantId $T -AdminSubscriptionId $A -PersistentSubscriptionId $P } |
                Should -Throw
            Should -Invoke Get-AvmBicepTestPoolIndex -Exactly 0
        }
    }

    It 'requires distinct, valid tenant and protected subscription IDs for <Case>' -ForEach @(
        @{ Case = 'missing tenant' }
        @{ Case = 'malformed Admin ID' }
        @{ Case = 'empty Persistent ID' }
        @{ Case = 'tenant equals Admin' }
        @{ Case = 'Admin equals Persistent' }
    ) {
        $tenantId = $script:tenant
        $adminId = $script:admin
        $persistentId = $script:persistent
        switch ($Case) {
            'missing tenant' { $tenantId = '' }
            'malformed Admin ID' { $adminId = 'not-an-id' }
            'empty Persistent ID' { $persistentId = [guid]::Empty.ToString('D') }
            'tenant equals Admin' { $tenantId = $adminId }
            'Admin equals Persistent' { $adminId = $persistentId }
        }
        InModuleScope 'Avm.Authoring' -Parameters @{
            Json = $script:poolJson; T = $tenantId; A = $adminId; P = $persistentId
        } {
            param($Json, $T, $A, $P)
            Mock Get-AvmBicepTestPoolIndex { throw 'Invalid IDs reached random selection.' }
            { Select-AvmBicepTestPoolSubscription -PoolJson $Json `
                    -TenantId $T -AdminSubscriptionId $A -PersistentSubscriptionId $P } |
                Should -Throw
            Should -Invoke Get-AvmBicepTestPoolIndex -Exactly 0
        }
    }

    It 'fails closed if the selection helper returns an out-of-range index' {
        InModuleScope 'Avm.Authoring' -Parameters @{
            Json = $script:poolJson; T = $script:tenant
            A = $script:admin; P = $script:persistent
        } {
            param($Json, $T, $A, $P)
            Mock Get-AvmBicepTestPoolIndex { 28 }
            { Select-AvmBicepTestPoolSubscription -PoolJson $Json `
                    -TenantId $T -AdminSubscriptionId $A -PersistentSubscriptionId $P } |
                Should -Throw -ExpectedMessage '*invalid index*'
        }
    }

    It 'checks a selected candidate against fake account and management-group identity' {
        InModuleScope 'Avm.Authoring' -Parameters @{
            Json = $script:poolJson; T = $script:tenant
            A = $script:admin; P = $script:persistent
        } {
            param($Json, $T, $A, $P)
            Mock Get-AvmBicepTestPoolIndex { 0 }
            $selected = Select-AvmBicepTestPoolSubscription -PoolJson $Json `
                -TenantId $T -AdminSubscriptionId $A -PersistentSubscriptionId $P
            $script:fakePoolAccount = [pscustomobject]@{
                SubscriptionId = $selected.SubscriptionId
                TenantId       = $selected.TenantId
                State          = 'Enabled'
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                if ($ArgumentList[0] -eq 'account' -and $ArgumentList[1] -eq 'show') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = (@{
                                id       = $script:fakePoolAccount.SubscriptionId
                                tenantId = $script:fakePoolAccount.TenantId
                                state    = $script:fakePoolAccount.State
                            } | ConvertTo-Json -Compress)
                        StdErr   = ''
                    }
                }
                if ($ArgumentList[0] -eq 'account' -and $ArgumentList[1] -eq 'management-group') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = '{"id":"/providers/Microsoft.Management/managementGroups/avm-test","name":"avm-test"}'
                        StdErr   = ''
                    }
                }
                throw "Unexpected CLI command: $($ArgumentList -join ' ')"
            }

            Assert-AvmBicepScopedAccount -AzPath 'fake-az' `
                -SubscriptionId $selected.SubscriptionId -TenantId $selected.TenantId `
                -ManagementGroupId 'avm-test' -WorkingDirectory '.'
            $script:fakePoolAccount.SubscriptionId = $A
            { Assert-AvmBicepScopedAccount -AzPath 'fake-az' `
                    -SubscriptionId $selected.SubscriptionId -TenantId $selected.TenantId `
                    -ManagementGroupId 'avm-test' -WorkingDirectory '.' } | Should -Throw
            $script:fakePoolAccount.SubscriptionId = $selected.SubscriptionId
            $script:fakePoolAccount.TenantId = $A
            { Assert-AvmBicepScopedAccount -AzPath 'fake-az' `
                    -SubscriptionId $selected.SubscriptionId -TenantId $selected.TenantId `
                    -ManagementGroupId 'avm-test' -WorkingDirectory '.' } | Should -Throw
            $script:fakePoolAccount.TenantId = $selected.TenantId
            $script:fakePoolAccount.State = 'Disabled'
            { Assert-AvmBicepScopedAccount -AzPath 'fake-az' `
                    -SubscriptionId $selected.SubscriptionId -TenantId $selected.TenantId `
                    -ManagementGroupId 'avm-test' -WorkingDirectory '.' } | Should -Throw
        }
    }
}
