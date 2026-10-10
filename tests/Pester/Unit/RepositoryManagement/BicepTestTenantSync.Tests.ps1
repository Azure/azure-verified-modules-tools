BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:syncScripts = Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts'
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:root 'repository-management' 'shared' 'TestTenant.ps1')
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'RetryHelpers.ps1')
    . (Join-Path $script:syncScripts 'lib' 'GitHubVariables.ps1')
    . (Join-Path $script:syncScripts 'lib' 'TestTenantSync.ps1')
    $script:executionNames = @(
        'VALIDATE_TENANT_ID', 'VALIDATE_CLIENT_ID', 'VALIDATE_SUBSCRIPTION_IDS',
        'VALIDATE_MANAGEMENT_GROUP_ID', 'VALIDATE_PERSISTENT_SUBSCRIPTION_ID'
    )

    function New-BicepSyncTestBundle {
        [ordered]@{
            TEST_BAMI_TENANT_ID = '11111111-1111-4111-8111-111111111111'
            TEST_BAMI_CONTROLLER_CLIENT_ID = '22222222-2222-4222-8222-222222222222'
            TEST_BAMI_ADMIN_SUBSCRIPTION_ID = '33333333-3333-4333-8333-333333333333'
            TEST_BAMI_SUBSCRIPTION_IDS = @(
                1..28 | ForEach-Object {
                    @{ name = "bami-sub-$_"; id = ('66666666-6666-4666-8666-{0:d12}' -f $_) }
                }
            )
            TEST_BAMI_MANAGEMENT_GROUP_ID = 'bami-test'
            TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME = 'rg-bami-test'
            TEST_BAMI_BICEP_CLIENT_ID = '44444444-4444-4444-8444-444444444444'
            TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID = '55555555-5555-4555-8555-555555555555'
        }
    }

    function Copy-BicepSyncTestSnapshot {
        param([System.Collections.IDictionary] $Snapshot)

        $copy = [ordered]@{}
        foreach ($name in $Snapshot.Keys) {
            $copy[$name] = if ($null -eq $Snapshot[$name]) { $null } else {
                [pscustomobject]@{
                    Name = $Snapshot[$name].Name
                    Value = $Snapshot[$name].Value
                    CreatedAt = $Snapshot[$name].CreatedAt
                    UpdatedAt = $Snapshot[$name].UpdatedAt
                }
            }
        }
        return $copy
    }

    function Set-BicepSyncTestValue {
        param([string] $Name, [AllowEmptyString()] [string] $Value, [string] $Revision = 'initial')

        $created = if ($null -ne $script:consumer[$Name]) { $script:consumer[$Name].CreatedAt } else { 'created' }
        $script:consumer[$Name] = [pscustomobject]@{
            Name = $Name
            Value = $Value
            CreatedAt = $created
            UpdatedAt = $Revision
        }
    }

    function Initialize-BicepSyncTestCandidate {
        foreach ($name in $script:projection.Keys) {
            Set-BicepSyncTestValue -Name $name -Value $script:projection[$name]
        }
    }

    function New-BicepSyncApiResponse {
        param([object] $Data, [int] $ExitCode = 0, [string] $StdErr = '')

        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = ConvertTo-Json -InputObject $Data -Depth 10 -Compress; StdErr = $StdErr }
    }

    function New-BicepSyncApiVariable {
        param([string] $Name = 'VALIDATE_TENANT_ID', [string] $Value = 'fixture-value')

        @{
            name = $Name
            value = $Value
            created_at = '2026-09-01T00:00:00Z'
            updated_at = '2026-09-15T00:00:00Z'
        }
    }
}

Describe 'Guarded nonsecret Bicep variable publication' {
    BeforeEach {
        $script:values = New-BicepSyncTestBundle
        $execution = Get-AvmBamiSettings -Values $script:values -BicepOnly
        $script:projection = [ordered]@{
            VALIDATE_TENANT_ID = $execution.TEST_BAMI_TENANT_ID
            VALIDATE_CLIENT_ID = $execution.TEST_BAMI_BICEP_CLIENT_ID
            VALIDATE_PERSISTENT_SUBSCRIPTION_ID = $execution.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
            VALIDATE_MANAGEMENT_GROUP_ID = $execution.TEST_BAMI_MANAGEMENT_GROUP_ID
            VALIDATE_SUBSCRIPTION_IDS = $execution.TEST_BAMI_SUBSCRIPTION_IDS
        }
        $script:consumer = [ordered]@{}
        foreach ($variableName in $script:executionNames) { $script:consumer[$variableName] = $null }
        $script:events = [System.Collections.Generic.List[string]]::new()
        $script:attempts = [System.Collections.Generic.List[object]]::new()
        $script:reads = 0
        $script:onRead = $null
        $script:beforeWrite = $null
        $script:afterWrite = $null
        $script:waits = [System.Collections.Generic.List[int]]::new()
        Mock Start-Sleep { param($Seconds) $script:waits.Add($Seconds) }
        Mock Write-Information {}
        Mock Get-AvmBicepTestTenantSnapshot {
            $script:reads++
            $script:events.Add("read:$script:reads")
            if ($script:onRead) { & $script:onRead $script:reads }
            Copy-BicepSyncTestSnapshot -Snapshot $script:consumer
        }
        Mock Invoke-AvmBicepTestTenantVariableApi {
            param($Method, $Name, $Value)
            if ($Method -cnotin @('POST', 'PATCH')) { throw 'Unexpected API call in the publication test.' }
            $script:events.Add("write:$Name")
            $script:attempts.Add([pscustomobject]@{ Method = $Method; Name = $Name; Value = $Value })
            if ($script:beforeWrite) { & $script:beforeWrite $Name $Value }
            Set-BicepSyncTestValue -Name $Name -Value $Value -Revision "write-$($script:attempts.Count)"
            if ($script:afterWrite) { & $script:afterWrite $Name $Value }
        }
        Mock Invoke-RepositorySyncProcess { throw 'Publication tests must not launch processes.' }
    }

    It 'defaults to a read-only plan containing only five execution names' {
        $result = Invoke-AvmBicepTestTenantSync -Values $script:values
        $result.Status | Should -BeExactly 'Planned'
        $result.PlanOnly | Should -BeTrue
        $result.Target | Should -BeExactly 'Azure/bicep-registry-modules'
        @($result.ChangedNames | Sort-Object) | Should -Be @($script:executionNames | Sort-Object)
        @($result.PSObject.Properties.Name | Sort-Object) | Should -Be @(
            'ChangedNames', 'HasChanges', 'PlanOnly', 'Status', 'Target'
        )
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 1
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
        $result | ConvertTo-Json -Depth 5 | Should -Not -Match '11111111|22222222|33333333|44444444|55555555|rg-bami-test'
    }

    It 'requires an explicit apply flag rather than accepting PlanOnly false' {
        { Invoke-AvmBicepTestTenantSync -Values $script:values -PlanOnly:$false } |
            Should -Throw '*Use -Apply explicitly*'
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 0
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'maps only the five validated source fields without renaming or mutating the source bundle' {
        $before = $script:values | ConvertTo-Json -Depth 8 -Compress
        $bundle = Get-AvmBamiSettings -Values $script:values
        $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Apply
        $result.Status | Should -BeExactly 'Published'
        $script:values | ConvertTo-Json -Depth 8 -Compress | Should -BeExactly $before
        $bundle.Count | Should -Be 8
        @($bundle.Keys | Where-Object { $_ -cnotlike 'TEST_BAMI_*' }) | Should -HaveCount 0
        $sourceNames = @(
            'TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_SUBSCRIPTION_IDS',
            'TEST_BAMI_MANAGEMENT_GROUP_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID'
        )
        for ($i = 0; $i -lt $sourceNames.Count; $i++) {
            $script:consumer[$script:executionNames[$i]].Value | Should -BeExactly $bundle[$sourceNames[$i]]
        }
        @($result.ChangedNames | Sort-Object) | Should -Be @($script:executionNames | Sort-Object)
    }

    It 'does not write for an explicitly false apply switch or WhatIf' {
        $plan = Invoke-AvmBicepTestTenantSync -Values $script:values -Apply:$false
        $preview = Invoke-AvmBicepTestTenantSync -Values $script:values -Apply -WhatIf
        $plan.Status | Should -BeExactly 'Planned'
        $plan.PlanOnly | Should -BeTrue
        $preview.Status | Should -BeExactly 'Preview'
        $preview.PlanOnly | Should -BeTrue
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'rejects a missing full-bundle setting before even reading the consumer' -ForEach @(
        'TEST_BAMI_TENANT_ID', 'TEST_BAMI_CONTROLLER_CLIENT_ID', 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID',
        'TEST_BAMI_SUBSCRIPTION_IDS', 'TEST_BAMI_MANAGEMENT_GROUP_ID', 'TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME',
        'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID'
    ) {
        $script:values.Remove($_)
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } | Should -Throw
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 0
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'rejects invalid full-bundle input before API writes: <Case>' -ForEach @(
        @{ Case = 'tenant'; Change = { param($v) $v.TEST_BAMI_TENANT_ID = 'not-a-guid' } }
        @{ Case = 'controller'; Change = { param($v) $v.TEST_BAMI_CONTROLLER_CLIENT_ID = 'not-a-guid' } }
        @{ Case = 'admin'; Change = { param($v) $v.TEST_BAMI_ADMIN_SUBSCRIPTION_ID = 'not-a-guid' } }
        @{ Case = 'Bicep client'; Change = { param($v) $v.TEST_BAMI_BICEP_CLIENT_ID = 'not-a-guid' } }
        @{ Case = 'persistent subscription'; Change = { param($v) $v.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID = 'not-a-guid' } }
        @{ Case = 'equal clients'; Change = { param($v) $v.TEST_BAMI_BICEP_CLIENT_ID = $v.TEST_BAMI_CONTROLLER_CLIENT_ID } }
        @{ Case = '27 subscriptions'; Change = { param($v) $v.TEST_BAMI_SUBSCRIPTION_IDS = @($v.TEST_BAMI_SUBSCRIPTION_IDS[0..26]) } }
        @{ Case = '29 subscriptions'; Change = { param($v) $v.TEST_BAMI_SUBSCRIPTION_IDS += @{ name = 'extra'; id = '77777777-7777-4777-8777-777777777777' } } }
        @{ Case = 'duplicate subscription ID'; Change = { param($v) $v.TEST_BAMI_SUBSCRIPTION_IDS[1].id = $v.TEST_BAMI_SUBSCRIPTION_IDS[0].id } }
        @{ Case = 'duplicate subscription name'; Change = { param($v) $v.TEST_BAMI_SUBSCRIPTION_IDS[1].name = $v.TEST_BAMI_SUBSCRIPTION_IDS[0].name } }
        @{ Case = 'persistent subscription in test pool'; Change = { param($v) $v.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID = $v.TEST_BAMI_SUBSCRIPTION_IDS[0].id } }
        @{ Case = 'admin subscription in test pool'; Change = { param($v) $v.TEST_BAMI_ADMIN_SUBSCRIPTION_ID = $v.TEST_BAMI_SUBSCRIPTION_IDS[0].id } }
        @{ Case = 'admin equals persistent subscription'; Change = { param($v) $v.TEST_BAMI_ADMIN_SUBSCRIPTION_ID = $v.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID } }
        @{ Case = 'malformed subscription JSON'; Change = { param($v) $v.TEST_BAMI_SUBSCRIPTION_IDS = '{' } }
        @{ Case = 'non-array subscription JSON'; Change = { param($v) $v.TEST_BAMI_SUBSCRIPTION_IDS = '{"name":"not-a-pool"}' } }
        @{ Case = 'duplicate subscription property'; Change = { param($v) $v.TEST_BAMI_SUBSCRIPTION_IDS = '[{"name":"first","Name":"second","id":"66666666-6666-4666-8666-000000000001"}]' } }
        @{ Case = 'additional subscription property'; Change = { param($v) $v.TEST_BAMI_SUBSCRIPTION_IDS[0].extra = 'invalid' } }
        @{ Case = 'management group'; Change = { param($v) $v.TEST_BAMI_MANAGEMENT_GROUP_ID = 'not/a/group' } }
        @{ Case = 'identity resource group'; Change = { param($v) $v.TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME = 'invalid?group' } }
    ) {
        & $Change $script:values
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } | Should -Throw
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 0
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'normalizes JSON or native subscription arrays and verifies all five published values' -ForEach @($false, $true) {
        if ($_) { $script:values.TEST_BAMI_SUBSCRIPTION_IDS = $script:values.TEST_BAMI_SUBSCRIPTION_IDS | ConvertTo-Json -Depth 5 }
        $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Apply
        $result.Status | Should -BeExactly 'Published'
        $result.PlanOnly | Should -BeFalse
        $script:attempts | Should -HaveCount 5
        @($script:attempts.Name | Sort-Object) | Should -Be @($script:executionNames | Sort-Object)
        @($script:attempts.Name) | Should -Not -Contain 'TEST_BAMI_CONTROLLER_CLIENT_ID'
        @($script:attempts.Name) | Should -Not -Contain 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID'
        @($script:attempts.Name) | Should -Not -Contain 'TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME'
        foreach ($name in $script:executionNames) {
            $script:consumer[$name].Value | Should -BeExactly $script:projection[$name]
        }
        $subscriptions = $script:consumer.VALIDATE_SUBSCRIPTION_IDS.Value
        @($subscriptions | ConvertFrom-Json) | Should -HaveCount 28
        $subscriptions | Should -Not -Match '\r|\n'
        $lastWrite = $script:events.IndexOf("write:$($script:attempts[-1].Name)")
        @($script:events[($lastWrite + 1)..($script:events.Count - 1)] | Where-Object { $_ -like 'read:*' }) | Should -HaveCount 3
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 13
        @($script:attempts.Method | Select-Object -Unique) | Should -Be @('POST')
    }

    It 'returns a no-op for an unchanged active candidate without touching any values' {
        Initialize-BicepSyncTestCandidate
        $script:values.TEST_BAMI_CONTROLLER_CLIENT_ID = '77777777-7777-4777-8777-777777777777'
        $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Apply
        $result.Status | Should -BeExactly 'NoChange'
        $result.HasChanges | Should -BeFalse
        $result.ChangedNames | Should -HaveCount 0
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 3
    }

    It 'is a no-op on a second identical apply and does not patch already-equal values' {
        $first = Invoke-AvmBicepTestTenantSync -Values $script:values -Apply
        $second = Invoke-AvmBicepTestTenantSync -Values $script:values -Apply
        $first.Status | Should -BeExactly 'Published'
        $second.Status | Should -BeExactly 'NoChange'
        $script:attempts | Should -HaveCount 5
    }

    Context 'Acknowledged write readback visibility' {
        BeforeEach {
            Initialize-BicepSyncTestCandidate
            $script:visibilityName = 'VALIDATE_SUBSCRIPTION_IDS'
            $script:consumer[$script:visibilityName] = $null
            $script:visibilityBefore = $null
            $script:visibilityReads = 0
            $script:staleReads = 1
            $script:beforeWrite = {
                param($Name)
                if ($Name -ceq $script:visibilityName) {
                    $script:visibilityBefore = Copy-BicepSyncTestSnapshot -Snapshot $script:consumer
                }
            }
            Mock Get-AvmBicepTestTenantSnapshot {
                $script:reads++
                $script:events.Add("read:$script:reads")
                if ($script:onRead) { & $script:onRead $script:reads }
                if ($null -ne $script:visibilityBefore -and $script:attempts[-1].Name -ceq $script:visibilityName) {
                    $script:visibilityReads++
                    if ($script:visibilityReads -le $script:staleReads) {
                        return Copy-BicepSyncTestSnapshot -Snapshot $script:visibilityBefore
                    }
                }
                Copy-BicepSyncTestSnapshot -Snapshot $script:consumer
            }
        }

        It 'waits only for GET visibility after <Method>, settling after <StaleReads> stale reads' -ForEach @(
            @{ Method = 'POST'; StaleReads = 1 }
            @{ Method = 'POST'; StaleReads = 3 }
            @{ Method = 'PATCH'; StaleReads = 1 }
            @{ Method = 'PATCH'; StaleReads = 3 }
        ) {
            if ($Method -ceq 'PATCH') {
                Set-BicepSyncTestValue -Name $script:visibilityName -Value 'old-pool'
            }
            $script:staleReads = $StaleReads
            $expected = Copy-BicepSyncTestSnapshot -Snapshot $script:consumer
            $result = Set-AvmBicepTestTenantVariable -Expected $expected -Name $script:visibilityName `
                -Value $script:projection[$script:visibilityName]
            $result[$script:visibilityName].Value | Should -BeExactly $script:projection[$script:visibilityName]
            $script:attempts | Should -HaveCount 1
            $script:attempts[0].Method | Should -BeExactly $Method
            $script:waits | Should -Be @(1..$StaleReads | ForEach-Object { 5 * $_ })
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly ($StaleReads + 2)
            Should -Invoke Write-Information -Exactly $StaleReads -ParameterFilter {
                $MessageData -clike '*readback visibility of VALIDATE_SUBSCRIPTION_IDS; retrying only the GET, not the acknowledged write.'
            }
        }

        It 'stops after four stale readbacks and 30 seconds of waits without retrying writes or rolling back' {
            $script:staleReads = 4
            { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
                Should -Throw '*Readback mismatch after writing VALIDATE_SUBSCRIPTION_IDS*after 4 readback attempt*'
            $script:waits | Should -Be @(5, 10, 15)
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 6
            @($script:attempts.Name) | Should -Be @($script:visibilityName)
            $script:consumer[$script:visibilityName].Value | Should -BeExactly $script:projection[$script:visibilityName]
        }

        It 'stops on a changed <Name> during a later readback without waiting again' -ForEach @(
            @{ Name = 'VALIDATE_TENANT_ID' }
            @{ Name = 'VALIDATE_CLIENT_ID' }
            @{ Name = 'VALIDATE_SUBSCRIPTION_IDS' }
        ) {
            $script:driftName = $Name
            $script:onRead = {
                param($Read)
                if ($Read -eq 4) {
                    Set-BicepSyncTestValue -Name $script:driftName -Value 'outside-value' -Revision 'outside'
                }
            }
            { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
                Should -Throw "*Readback mismatch after writing*${Name}*"
            $script:waits | Should -Be @(5)
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 4
            @($script:attempts.Name) | Should -Be @($script:visibilityName)
            $script:consumer[$Name].Value | Should -BeExactly 'outside-value'
        }

        It 'does not treat the old written value with changed <Field> as stale visibility' -ForEach @(
            @{ Field = 'CreatedAt' }
            @{ Field = 'UpdatedAt' }
        ) {
            Set-BicepSyncTestValue -Name $script:visibilityName -Value 'old-pool'
            $script:changedField = $Field
            $script:afterWrite = {
                $script:visibilityBefore[$script:visibilityName].($script:changedField) = 'outside'
            }
            $expected = Copy-BicepSyncTestSnapshot -Snapshot $script:consumer
            { Set-AvmBicepTestTenantVariable -Expected $expected -Name $script:visibilityName -Value $script:projection[$script:visibilityName] } |
                Should -Throw '*Readback mismatch after writing*'
            Should -Invoke Start-Sleep -Exactly 0
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 2
            $script:attempts | Should -HaveCount 1
        }

        It 'fails immediately if a later visibility GET fails' {
            $script:onRead = {
                param($Read)
                if ($Read -eq 4) { throw [System.IO.IOException]::new('Readback unavailable.') }
            }
            { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
                Should -Throw '*was acknowledged, and consumer readback failed*outcome is unverified*'
            $script:waits | Should -Be @(5)
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 4
            $script:attempts | Should -HaveCount 1
        }

        It 'never waits or retries an unacknowledged write with <StaleReads> stale reads' -ForEach @(
            @{ StaleReads = 0 }
            @{ StaleReads = 1 }
        ) {
            $script:staleReads = $StaleReads
            $script:afterWrite = { throw [System.TimeoutException]::new('Response lost.') }
            { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
                Should -Throw '*was not acknowledged*No write retry or rollback was attempted*'
            Should -Invoke Start-Sleep -Exactly 0
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 3
            $script:attempts | Should -HaveCount 1
        }

        It 'verifies the complete bundle after an initialized execution value becomes visible' {
            $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Apply
            $result.Status | Should -BeExactly 'Published'
            $script:waits | Should -Be @(5)
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 6
            @($script:attempts.Name) | Should -Be @($script:visibilityName)
            foreach ($name in $script:projection.Keys) {
                $script:consumer[$name].Value | Should -BeExactly $script:projection[$name]
            }
        }
    }

    It 'refuses each changed execution value and requires coordinated maintenance: <Name>' -ForEach @(
        @{ Name = 'VALIDATE_TENANT_ID'; SourceName = 'TEST_BAMI_TENANT_ID'; Value = '77777777-7777-4777-8777-777777777777' }
        @{ Name = 'VALIDATE_CLIENT_ID'; SourceName = 'TEST_BAMI_BICEP_CLIENT_ID'; Value = '77777777-7777-4777-8777-777777777777' }
        @{ Name = 'VALIDATE_SUBSCRIPTION_IDS'; SourceName = 'TEST_BAMI_SUBSCRIPTION_IDS'; Value = 'subscriptions' }
        @{ Name = 'VALIDATE_MANAGEMENT_GROUP_ID'; SourceName = 'TEST_BAMI_MANAGEMENT_GROUP_ID'; Value = 'other-bami-group' }
        @{ Name = 'VALIDATE_PERSISTENT_SUBSCRIPTION_ID'; SourceName = 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID'; Value = '77777777-7777-4777-8777-777777777777' }
    ) {
        Initialize-BicepSyncTestCandidate
        if ($Name -ceq 'VALIDATE_SUBSCRIPTION_IDS') {
            $script:values[$SourceName][0].id = '77777777-7777-4777-8777-777777777777'
        }
        else { $script:values[$SourceName] = $Value }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
            Should -Throw '*Existing BAMI execution values cannot change*coordinated maintenance*'
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'also refuses planning an unsafe active retarget instead of producing an applicable plan' {
        Initialize-BicepSyncTestCandidate
        $script:values.TEST_BAMI_TENANT_ID = '77777777-7777-4777-8777-777777777777'
        { Invoke-AvmBicepTestTenantSync -Values $script:values } |
            Should -Throw '*Existing BAMI execution values cannot change*'
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'refuses a completely different existing tuple without returning a success or applicable plan' -ForEach @($false, $true) {
        foreach ($name in $script:executionNames) {
            Set-BicepSyncTestValue -Name $name -Value 'different-existing-value'
        }
        $failure = $null
        try { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply:$_ }
        catch { $failure = $_.Exception.Message }
        $failure | Should -BeLike '*coordinated maintenance*'
        foreach ($name in $script:executionNames) {
            $failure | Should -Match ([regex]::Escape($name))
            $script:consumer[$name].Value | Should -BeExactly 'different-existing-value'
        }
        $failure | Should -Not -Match 'different-existing-value'
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'initializes each missing field without rewriting the matching present values' -ForEach @(
        'VALIDATE_TENANT_ID', 'VALIDATE_CLIENT_ID', 'VALIDATE_SUBSCRIPTION_IDS',
        'VALIDATE_MANAGEMENT_GROUP_ID', 'VALIDATE_PERSISTENT_SUBSCRIPTION_ID'
    ) {
        Initialize-BicepSyncTestCandidate
        $script:consumer[$_] = $null
        $initial = Copy-BicepSyncTestSnapshot -Snapshot $script:consumer
        $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Apply
        $result.Status | Should -BeExactly 'Published'
        @($result.ChangedNames) | Should -Be @($_)
        @($script:attempts.Name) | Should -Be @($_)
        $script:attempts[0].Method | Should -BeExactly 'POST'
        foreach ($name in $script:executionNames | Where-Object { $null -ne $initial[$_] }) {
            $script:consumer[$name].Value | Should -BeExactly $initial[$name].Value
            $script:consumer[$name].UpdatedAt | Should -BeExactly $initial[$name].UpdatedAt
        }
    }

    It 'refuses every mismatching present value even in an otherwise absent tuple' -ForEach @(
        'VALIDATE_TENANT_ID', 'VALIDATE_CLIENT_ID', 'VALIDATE_SUBSCRIPTION_IDS',
        'VALIDATE_MANAGEMENT_GROUP_ID', 'VALIDATE_PERSISTENT_SUBSCRIPTION_ID'
    ) {
        foreach ($value in @('', 'outside-value')) {
            Set-BicepSyncTestValue -Name $_ -Value $value
            { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
                Should -Throw '*Existing BAMI execution values cannot change*coordinated maintenance*'
            { Invoke-AvmBicepTestTenantSync -Values $script:values } |
                Should -Throw '*Existing BAMI execution values cannot change*'
        }
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'rejects retired selector and arbitrary writes before reading or writing the consumer' -ForEach @(
        'TEST_BAMI_MODULE_PATHS', 'ARM_TENANT_ID', 'TEST_BAMI_CONTROLLER_CLIENT_ID', 'arbitrary',
        'TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_SUBSCRIPTION_IDS',
        'TEST_BAMI_MANAGEMENT_GROUP_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID',
        'TEST_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_ID', 'ARM_MGMTGROUP_ID'
    ) {
        { Set-AvmBicepTestTenantVariable -Expected $script:consumer -Name $_ -Value 'value' } |
            Should -Throw '*Only the five Bicep execution variables*'
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 0
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'honors ShouldProcess at the individual variable boundary' {
        { Set-AvmBicepTestTenantVariable -Expected $script:consumer -Name 'VALIDATE_TENANT_ID' -Value $script:projection.VALIDATE_TENANT_ID -WhatIf } |
            Should -Throw '*not approved*'
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 0
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'stops on first and late write failures without retry or rollback' -ForEach @(0, 4) {
        $script:failedName = @($script:projection.Keys)[$_]
        $script:beforeWrite = {
            param($Name)
            if ($Name -ceq $script:failedName) { throw [System.IO.IOException]::new('Write failed.') }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
            Should -Throw '*not acknowledged*Readback does not match*'
        $script:attempts | Should -HaveCount ($_ + 1)
        @($script:attempts | Where-Object Name -CEQ $script:failedName) | Should -HaveCount 1
        $script:consumer[$script:failedName] | Should -BeNullOrEmpty
        foreach ($attempt in @($script:attempts | Where-Object Name -CNE $script:failedName)) {
            $script:consumer[$attempt.Name].Value | Should -BeExactly $attempt.Value
        }
    }

    It 'verifies successful execution writes with lost responses, then fails without reporting success' -ForEach @(0, 4) {
        $script:failedName = @($script:projection.Keys)[$_]
        $script:afterWrite = {
            param($Name)
            if ($Name -ceq $script:failedName) { throw [System.TimeoutException]::new('Response lost.') }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
            Should -Throw '*not acknowledged*Readback confirms the requested execution value is present and other execution values are unchanged*'
        $script:attempts | Should -HaveCount ($_ + 1)
        $script:consumer[$script:failedName].Value | Should -BeExactly $script:projection[$script:failedName]
        $script:events[-1] | Should -BeLike 'read:*'
    }

    It 'reports unknown outcomes when write readback fails: field <Index>, lost response <Lost>' -ForEach @(
        @{ Index = 0; Lost = $false }
        @{ Index = 0; Lost = $true }
        @{ Index = 4; Lost = $false }
        @{ Index = 4; Lost = $true }
    ) {
        $script:failedName = @($script:projection.Keys)[$Index]
        $script:loseResponse = $Lost
        $script:afterWrite = {
            param($Name)
            if ($script:loseResponse -and $Name -ceq $script:failedName) { throw [System.TimeoutException]::new('Response lost.') }
        }
        $script:onRead = {
            if ($script:attempts.Count -gt 0 -and $script:attempts[-1].Name -ceq $script:failedName) {
                throw [System.IO.IOException]::new('Readback unavailable.')
            }
        }
        $expected = if ($Lost) { '*was not acknowledged, and consumer readback failed*outcome is unverified*' } else { '*was acknowledged, and consumer readback failed*outcome is unverified*' }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } | Should -Throw $expected
        @($script:attempts | Where-Object Name -CEQ $script:failedName) | Should -HaveCount 1
        $script:consumer[$script:failedName] | Should -Not -BeNullOrEmpty
    }

    It 'detects a mismatching acknowledged write and preserves the observed value without rollback' -ForEach @(0, 4) {
        $script:failedName = @($script:projection.Keys)[$_]
        $script:afterWrite = {
            param($Name)
            if ($Name -ceq $script:failedName) { Set-BicepSyncTestValue -Name $Name -Value 'outside-value' -Revision 'outside' }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
            Should -Throw '*Readback mismatch after writing*'
        $script:consumer[$script:failedName].Value | Should -BeExactly 'outside-value'
        $script:attempts | Should -HaveCount ($_ + 1)
    }

    It 'does not overwrite an outside edit found before the first write' {
        $script:onRead = {
            param($Read)
            if ($Read -eq 2) { Set-BicepSyncTestValue -Name 'VALIDATE_TENANT_ID' -Value 'outside-value' -Revision 'outside' }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
            Should -Throw '*changed outside this sync during pre-write*'
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        $script:consumer.VALIDATE_TENANT_ID.Value | Should -BeExactly 'outside-value'
    }

    It 'detects outside changes between writes before overwriting the next planned value' {
        $script:nextName = @($script:projection.Keys)[1]
        $script:onRead = {
            param($Read)
            if ($Read -eq 4) { Set-BicepSyncTestValue -Name $script:nextName -Value 'outside-value' -Revision 'outside' }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
            Should -Throw '*changed outside this sync during pre-write*'
        $script:attempts | Should -HaveCount 1
        $script:consumer[$script:nextName].Value | Should -BeExactly 'outside-value'
    }

    It 'detects an outside execution change during a value write without rolling it back' {
        $script:afterWrite = {
            Set-BicepSyncTestValue -Name 'VALIDATE_CLIENT_ID' -Value 'outside-value' -Revision 'outside'
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
            Should -Throw '*Partial execution values or outside edits may remain*Readback mismatch*VALIDATE_CLIENT_ID*'
        $script:attempts | Should -HaveCount 1
        $script:consumer.VALIDATE_CLIENT_ID.Value | Should -BeExactly 'outside-value'
    }

    It 'detects drift at complete and final readback with or without preceding writes' -ForEach @(
        @{ Read = 2; ExpectedWrites = 0; Stage = 'complete execution-value readback' }
        @{ Read = 3; ExpectedWrites = 0; Stage = 'final publication readback' }
        @{ Read = 4; ExpectedWrites = 1; Stage = 'complete execution-value readback' }
        @{ Read = 5; ExpectedWrites = 1; Stage = 'final publication readback' }
    ) {
        Initialize-BicepSyncTestCandidate
        if ($ExpectedWrites -eq 1) { $script:consumer.VALIDATE_TENANT_ID = $null }
        $script:driftRead = $Read
        $script:onRead = {
            param($Read)
            if ($Read -eq $script:driftRead) {
                Set-BicepSyncTestValue -Name 'VALIDATE_CLIENT_ID' -Value 'outside-value' -Revision 'outside'
            }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
            Should -Throw "*changed outside this sync during ${Stage}*"
        $script:attempts | Should -HaveCount $ExpectedWrites
        $script:consumer.VALIDATE_CLIENT_ID.Value | Should -BeExactly 'outside-value'
    }

    It 'fails honestly if complete or final readback is unavailable after initialization' -ForEach @(12, 13) {
        $script:failedRead = $_
        $script:onRead = {
            param($Read)
            if ($Read -eq $script:failedRead) { throw [System.IO.IOException]::new('Readback unavailable.') }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
            Should -Throw '*publication is unverified*No automatic rollback or write retry*Readback unavailable*'
        $script:attempts | Should -HaveCount 5
        foreach ($name in $script:executionNames) {
            $script:consumer[$name].Value | Should -BeExactly $script:projection[$name]
        }
        Should -Invoke Start-Sleep -Exactly 0
    }

    It 'detects metadata-only edits even when candidate values remain identical' -ForEach @('CreatedAt', 'UpdatedAt') {
        Initialize-BicepSyncTestCandidate
        $script:changedField = $_
        $script:onRead = {
            param($Read)
            if ($Read -eq 3) { $script:consumer.VALIDATE_TENANT_ID.($script:changedField) = 'outside' }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
            Should -Throw '*changed outside this sync*VALIDATE_TENANT_ID*'
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'detects deletion and recreation of the variable being patched' {
        Initialize-BicepSyncTestCandidate
        $script:afterWrite = {
            param($Name)
            $script:consumer[$Name].CreatedAt = 'outside-recreation'
        }
        $expected = Copy-BicepSyncTestSnapshot -Snapshot $script:consumer
        { Set-AvmBicepTestTenantVariable -Expected $expected -Name 'VALIDATE_TENANT_ID' -Value $script:projection.VALIDATE_TENANT_ID } |
            Should -Throw '*Readback mismatch*VALIDATE_TENANT_ID*'
        $script:attempts | Should -HaveCount 1
        $script:consumer.VALIDATE_TENANT_ID.CreatedAt | Should -BeExactly 'outside-recreation'
        Should -Invoke Start-Sleep -Exactly 0
    }

    It 'detects a changed consumer during no-op verification instead of reporting success' {
        Initialize-BicepSyncTestCandidate
        $script:onRead = {
            param($Read)
            if ($Read -eq 2) { $script:consumer.VALIDATE_TENANT_ID = $null }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Apply } |
            Should -Throw '*changed outside this sync*'
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    Context 'Module client-ID publication' {
        BeforeEach {
            Initialize-BicepSyncTestCandidate
            $script:consumer['VALIDATE_MODULE_CLIENT_IDS'] = $null
            $script:clientIds = [ordered]@{
                'avm/res/fabric/capacity' = '10000000-0000-4000-8000-000000000006'
                'avm/res/storage/storage-account' = '10000000-0000-4000-8000-000000000016'
            }
        }

        It 'publishes and extends the compact mapping without changing the five existing values' {
            $result = Invoke-AvmBicepTestTenantSync -Values $script:values -ModuleClientIds $script:clientIds -Apply
            $result.ChangedNames | Should -Be @('VALIDATE_MODULE_CLIENT_IDS')
            $script:attempts | Should -HaveCount 1
            $script:attempts[0].Method | Should -BeExactly 'POST'
            $script:consumer.VALIDATE_MODULE_CLIENT_IDS.Value | Should -BeExactly (ConvertTo-AvmBicepModuleClientIdJson -ClientIds $script:clientIds)
            $script:clientIds['avm/res/new/service'] = '10000000-0000-4000-8000-000000000026'
            $result = Invoke-AvmBicepTestTenantSync -Values $script:values -ModuleClientIds $script:clientIds -Apply
            $result.Status | Should -BeExactly 'Published'
            $script:attempts | Should -HaveCount 2
            $script:attempts[1].Method | Should -BeExactly 'PATCH'
            foreach ($name in $script:executionNames) {
                $script:consumer[$name].Value | Should -BeExactly $script:projection[$name]
            }
            $result = Invoke-AvmBicepTestTenantSync -Values $script:values -ModuleClientIds $script:clientIds -Apply
            $result.Status | Should -BeExactly 'NoChange'
            $script:attempts | Should -HaveCount 2
        }

        It 'does not write mappings in a plan or WhatIf preview' {
            (Invoke-AvmBicepTestTenantSync -Values $script:values -ModuleClientIds $script:clientIds).Status |
                Should -BeExactly 'Planned'
            (Invoke-AvmBicepTestTenantSync -Values $script:values -ModuleClientIds $script:clientIds -Apply -WhatIf).Status |
                Should -BeExactly 'Preview'
            Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        }

        It 'rejects shared and controller client IDs before reading GitHub' -ForEach @('TEST_BAMI_CONTROLLER_CLIENT_ID', 'TEST_BAMI_BICEP_CLIENT_ID') {
            $script:clientIds['avm/res/fabric/capacity'] = $script:values[$_]
            { Invoke-AvmBicepTestTenantSync -Values $script:values -ModuleClientIds $script:clientIds -Apply } | Should -Throw
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 0
            Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        }

        It 'will not retarget or delete an existing module binding' -ForEach @('remove', 'replace') {
            Set-BicepSyncTestValue -Name 'VALIDATE_MODULE_CLIENT_IDS' -Value (ConvertTo-AvmBicepModuleClientIdJson -ClientIds $script:clientIds)
            if ($_ -ceq 'remove') { $script:clientIds.Remove('avm/res/fabric/capacity') }
            else { $script:clientIds['avm/res/fabric/capacity'] = '90000000-0000-4000-8000-000000000006' }
            { Invoke-AvmBicepTestTenantSync -Values $script:values -ModuleClientIds $script:clientIds -Apply } |
                Should -Throw '*removed or retargeted*'
            Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        }

        It 'detects shared-identity drift during mapping publication without a rollback' {
            $script:afterWrite = {
                Set-BicepSyncTestValue -Name 'VALIDATE_CLIENT_ID' -Value 'outside-value' -Revision 'outside'
            }
            { Invoke-AvmBicepTestTenantSync -Values $script:values -ModuleClientIds $script:clientIds -Apply } |
                Should -Throw '*Readback mismatch*VALIDATE_CLIENT_ID*'
            $script:attempts | Should -HaveCount 1
        }

        It 'reads back an unacknowledged mapping write but never retries it or reports success' {
            $script:afterWrite = { throw [System.IO.IOException]::new('Mapping response lost.') }
            { Invoke-AvmBicepTestTenantSync -Values $script:values -ModuleClientIds $script:clientIds -Apply } |
                Should -Throw '*not acknowledged*No write retry or rollback*'
            $script:attempts | Should -HaveCount 1
            Should -Invoke Start-Sleep -Exactly 0
        }
    }
}

Describe 'Narrow GitHub nonsecret variable adapter' {
    BeforeEach {
        $script:oldToken = $env:GH_TOKEN
        $script:oldOffline = $env:AVM_OFFLINE
        $env:GH_TOKEN = 'fixture-installation-token'
        $env:AVM_OFFLINE = '0'
        $script:response = New-BicepSyncApiResponse -Data @{ total_count = 0; variables = @() }
        Mock Invoke-RepositorySyncProcess { $script:response }
    }

    AfterEach {
        $env:GH_TOKEN = $script:oldToken
        $env:AVM_OFFLINE = $script:oldOffline
    }

    It 'uses the existing argv process adapter, fixed host and target, and an environment token' {
        $result = Invoke-AvmBicepTestTenantVariableApi -Page 2
        $result.total_count | Should -Be 0
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter {
            $Command -ceq 'gh' -and $TimeoutSec -eq 60 -and $Arguments -is [string[]] -and
            ($Arguments -join '|') -ceq 'api|--hostname|github.com|--method|GET|--header|Accept: application/vnd.github+json|--header|X-GitHub-Api-Version: 2022-11-28|--header|Cache-Control: no-cache|repos/Azure/bicep-registry-modules/actions/variables?per_page=100&page=2' -and
            $EnvVars.GH_TOKEN -ceq 'fixture-installation-token' -and
            $null -eq $EnvVars.GH_ENTERPRISE_TOKEN -and $null -eq $EnvVars.GITHUB_ENTERPRISE_TOKEN
        }
    }

    It 'uses POST for creation and PATCH for updates without shell interpolation or extra scopes' -ForEach @('POST', 'PATCH') {
        $payload = 'fixture-group'
        $null = Invoke-AvmBicepTestTenantVariableApi -Method $_ -Name 'VALIDATE_MANAGEMENT_GROUP_ID' -Value $payload
        $script:expectedMethod = $_
        $script:expectedEndpoint = 'repos/Azure/bicep-registry-modules/actions/variables'
        if ($_ -ceq 'PATCH') { $script:expectedEndpoint += '/VALIDATE_MANAGEMENT_GROUP_ID' }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter {
            $Arguments[4] -ceq $script:expectedMethod -and $Arguments[11] -ceq $script:expectedEndpoint -and
            $Arguments[12] -ceq '--raw-field' -and $Arguments[13] -ceq 'name=VALIDATE_MANAGEMENT_GROUP_ID' -and
            $Arguments[14] -ceq '--raw-field' -and $Arguments[15] -ceq 'value=fixture-group' -and
            $Arguments.Count -eq 16 -and ($Arguments -join '|') -cnotmatch 'fixture-installation-token|/secrets'
        }
    }

    It 'never falls back or retries when GitHub refuses access or returns a transient failure' -ForEach @(403, 404, 500) {
        $script:response = New-BicepSyncApiResponse -Data @{} -ExitCode 1 -StdErr "sensitive-diagnostic-sentinel (HTTP $_)"
        { Get-AvmBicepTestTenantSnapshot } | Should -Throw "*HTTP $_*"
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1
        $caught = $null
        try { Invoke-AvmBicepTestTenantVariableApi -Method 'PATCH' -Name 'VALIDATE_TENANT_ID' -Value 'fixture-value' }
        catch { $caught = $_.Exception.Message }
        $caught | Should -Not -BeNullOrEmpty
        $caught | Should -Not -Match 'sensitive-diagnostic-sentinel'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 2
    }

    It 'rejects retired selector, legacy, controller, administration, secret, and noncanonical names' -ForEach @(
        'TEST_BAMI_MODULE_PATHS',
        'ARM_TENANT_ID', 'TEST_BAMI_CONTROLLER_CLIENT_ID', 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID',
        'TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME', 'GH_TOKEN', 'validate_tenant_id', '../secrets/ANY',
        'TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_SUBSCRIPTION_IDS',
        'TEST_BAMI_MANAGEMENT_GROUP_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID',
        'TEST_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_ID', 'ARM_MGMTGROUP_ID'
    ) {
        { Invoke-AvmBicepTestTenantVariableApi -Method 'POST' -Name $_ -Value 'fixture-value' } | Should -Throw
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'refuses invalid request combinations and never deletes variables' {
        { Invoke-AvmBicepTestTenantVariableApi -Method 'DELETE' -Name 'VALIDATE_TENANT_ID' } | Should -Throw
        { Invoke-AvmBicepTestTenantVariableApi -Method 'POST' -Name 'VALIDATE_TENANT_ID' } | Should -Throw '*explicit value*'
        { Invoke-AvmBicepTestTenantVariableApi -Method 'POST' -Name 'VALIDATE_TENANT_ID' -Value 'value' -Page 1 } | Should -Throw '*pagination*'
        { Invoke-AvmBicepTestTenantVariableApi -Name 'VALIDATE_TENANT_ID' } | Should -Throw '*collection*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'requires an explicit installation token and honors offline mode and WhatIf' {
        $env:GH_TOKEN = ''
        { Invoke-AvmBicepTestTenantVariableApi } | Should -Throw '*explicit target-scoped*'
        $env:GH_TOKEN = 'fixture-installation-token'
        $env:AVM_OFFLINE = '1'
        { Invoke-AvmBicepTestTenantVariableApi } | Should -Throw '*AVM_OFFLINE=1*'
        $env:AVM_OFFLINE = '0'
        { Invoke-AvmBicepTestTenantVariableApi -Method 'POST' -Name 'VALIDATE_TENANT_ID' -Value 'value' -WhatIf } |
            Should -Throw '*not approved*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'snapshots the five execution variables and module mapping while ignoring old aliases and legacy values' {
        $unmanaged = @(
            'ARM_TENANT_ID', 'TEST_BAMI_CONTROLLER_CLIENT_ID', 'TEST_BAMI_MODULE_PATHS',
            'TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_SUBSCRIPTION_IDS',
            'TEST_BAMI_MANAGEMENT_GROUP_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID',
            'TEST_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_ID', 'ARM_MGMTGROUP_ID'
        )
        $script:response = New-BicepSyncApiResponse -Data @{
            total_count = 1 + $unmanaged.Count
            variables = @(
                New-BicepSyncApiVariable
                foreach ($name in $unmanaged) { New-BicepSyncApiVariable -Name $name -Value 'unmanaged-invalid-value' }
            )
        }
        $snapshot = Get-AvmBicepTestTenantSnapshot
        $snapshot.Count | Should -Be 6
        @($snapshot.Keys | Sort-Object) | Should -Be @((@($script:executionNames) + 'VALIDATE_MODULE_CLIENT_IDS') | Sort-Object)
        $snapshot.VALIDATE_TENANT_ID.Value | Should -BeExactly 'fixture-value'
        $snapshot.VALIDATE_TENANT_ID.CreatedAt | Should -BeExactly '2026-09-01T00:00:00.0000000Z'
        $snapshot.VALIDATE_TENANT_ID.UpdatedAt | Should -BeExactly '2026-09-15T00:00:00.0000000Z'
        foreach ($name in $unmanaged) { $snapshot.Contains($name) | Should -BeFalse }
    }

    It 'distinguishes genuinely absent variables from unreadable collection responses' {
        $snapshot = Get-AvmBicepTestTenantSnapshot
        $snapshot.Count | Should -Be 6
        @($snapshot.Values | Where-Object { $null -ne $_ }) | Should -HaveCount 0
        $script:response.StdOut = ''
        { Get-AvmBicepTestTenantSnapshot } | Should -Throw '*empty variable collection*'
        $script:response.StdOut = '{'
        { Get-AvmBicepTestTenantSnapshot } | Should -Throw '*invalid variable collection JSON*'
    }

    It 'refuses malformed, incomplete, or ambiguous variable snapshots: <Case>' -ForEach @(
        @{ Case = 'missing schema'; Data = @{} }
        @{ Case = 'missing entries'; Data = @{ total_count = 1; variables = @() } }
        @{ Case = 'string count'; Data = @{ total_count = '0'; variables = @() } }
        @{ Case = 'negative count'; Data = @{ total_count = -1; variables = @() } }
        @{ Case = 'wrong collection type'; Data = @{ total_count = 0; variables = @{} } }
        @{ Case = 'duplicate names'; Data = @{ total_count = 2; variables = @(@{ name = 'LEGACY' }, @{ name = 'legacy' }) } }
        @{ Case = 'missing name'; Data = @{ total_count = 1; variables = @(@{ value = 'value' }) } }
        @{ Case = 'noncanonical candidate name'; Data = @{ total_count = 1; variables = @(@{ name = 'validate_tenant_id'; value = 'value' }) } }
        @{ Case = 'missing candidate value'; Data = @{ total_count = 1; variables = @(@{ name = 'VALIDATE_TENANT_ID' }) } }
        @{ Case = 'missing timestamp'; Data = @{ total_count = 1; variables = @(@{ name = 'VALIDATE_TENANT_ID'; value = 'value' }) } }
        @{ Case = 'invalid timestamp'; Data = @{ total_count = 1; variables = @(@{ name = 'VALIDATE_TENANT_ID'; value = 'value'; created_at = 'not-a-date'; updated_at = 'not-a-date' }) } }
    ) {
        $script:response = New-BicepSyncApiResponse -Data $Data
        { Get-AvmBicepTestTenantSnapshot } | Should -Throw
    }

    It 'reads every page before treating an execution variable as absent' {
        $script:firstPage = @(1..99 | ForEach-Object { @{ name = "LEGACY_$_" } })
        $script:firstPage += New-BicepSyncApiVariable
        Mock Invoke-RepositorySyncProcess {
            param($Arguments)
            if ($Arguments[11] -clike '*page=1') {
                return New-BicepSyncApiResponse -Data @{ total_count = 101; variables = $script:firstPage }
            }
            New-BicepSyncApiResponse -Data @{
                total_count = 101
                variables = @((New-BicepSyncApiVariable -Name 'VALIDATE_MANAGEMENT_GROUP_ID' -Value 'fixture-group'))
            }
        }
        $snapshot = Get-AvmBicepTestTenantSnapshot
        $snapshot.VALIDATE_TENANT_ID.Value | Should -BeExactly 'fixture-value'
        $snapshot.VALIDATE_MANAGEMENT_GROUP_ID.Value | Should -BeExactly 'fixture-group'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 2
    }

    It 'rejects pagination drift instead of treating an inconsistent list as a safe snapshot' -ForEach @('count', 'duplicate', 'truncated') {
        $script:paginationFailure = $_
        Mock Invoke-RepositorySyncProcess {
            param($Arguments)
            if ($Arguments[11] -clike '*page=1') {
                return New-BicepSyncApiResponse -Data @{
                    total_count = 101
                    variables = @(1..100 | ForEach-Object { @{ name = "LEGACY_$_" } })
                }
            }
            $count = if ($script:paginationFailure -ceq 'count') { 102 } else { 101 }
            $entries = if ($script:paginationFailure -ceq 'truncated') { @() } else { @(@{ name = 'LEGACY_1' }) }
            New-BicepSyncApiResponse -Data @{ total_count = $count; variables = $entries }
        }
        { Get-AvmBicepTestTenantSnapshot } | Should -Throw
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 2
    }
}

Describe 'Bicep variable adapter uses Invoke-AvmProcess without exposing credentials' {
    BeforeEach {
        $script:oldToken = $env:GH_TOKEN
        $script:oldOffline = $env:AVM_OFFLINE
        $env:GH_TOKEN = 'fixture-installation-token'
        $env:AVM_OFFLINE = '0'
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"total_count":0,"variables":[]}'; StdErr = '' }
        }
    }

    AfterEach {
        $env:GH_TOKEN = $script:oldToken
        $env:AVM_OFFLINE = $script:oldOffline
    }

    It 'reaches the shared process boundary once with argv and no streaming or write retry' {
        $null = Invoke-AvmBicepTestTenantVariableApi -Method 'PATCH' -Name 'VALIDATE_MANAGEMENT_GROUP_ID' -Value 'fixture-group'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            [System.IO.Path]::IsPathRooted($FilePath) -and $ArgumentList -is [string[]] -and
            $ArgumentList[15] -ceq 'value=fixture-group' -and
            $EnvVars.GH_TOKEN -ceq 'fixture-installation-token' -and $EnvVars.GH_HOST -ceq 'github.com' -and
            $null -eq $EnvVars.GITHUB_TOKEN -and $null -eq $EnvVars.GH_DEBUG -and
            $EnvVars.GH_PROMPT_DISABLED -ceq '1' -and $IgnoreExitCode -and -not $StreamOutput -and $TimeoutSec -eq 60
        }
    }
}

Describe 'Bicep workflow isolation and trusted input boundary' {
    BeforeAll {
        $script:workflow = (Get-Content -LiteralPath (Join-Path $script:root '.github' 'workflows' 'repository-management-bicep-sync.yml') -Raw).Replace("`r`n", "`n")
        $script:variablesJob = [regex]::Match($script:workflow, '(?ms)^  sync-test-tenant-variables:\n.*?(?=^  [a-z][a-z-]+:\n|\z)').Value
        $script:identitiesJob = [regex]::Match($script:workflow, '(?ms)^  sync-module-identities:\n.*\z').Value
        $script:entry = Get-Content -LiteralPath (Join-Path $script:syncScripts 'Invoke-BicepTestTenantSync.ps1') -Raw
    }

    It 'reuses the sync workflow for identities and variables without restoring CODEOWNERS publication' {
        $jobs = @([regex]::Matches($script:workflow, '(?m)^  ([a-z][a-z-]+):\n    name:') |
            ForEach-Object { $_.Groups[1].Value })
        $jobs | Should -Be @('sync-test-tenant-variables', 'sync-module-identities')
        $script:workflow | Should -Not -Match 'BicepCodeownersSync|bicep-codeowners-sync|Generate and synchronize CODEOWNERS'
        Test-Path -LiteralPath (Join-Path $script:root 'repository-management' 'bicep-codeowners-sync') | Should -BeFalse
    }

    It 'retains the schedule and defaults manual runs to a non-applying plan' {
        $triggers = [regex]::Match($script:workflow, '(?ms)^on:\n(.*?)(?=^\S)').Groups[1].Value.TrimEnd()
        $triggers | Should -BeExactly (@(
            '  schedule:'
            "    - cron: '33 2-23/4 * * *'"
            '  workflow_dispatch:'
            '    inputs:'
            '      plan_only:'
            '        description: Plan identity and variable changes without applying'
            '        type: boolean'
            '        default: true'
        ) -join "`n")
        $script:workflow | Should -Not -Match 'enable_test_tenant_sync|AVM_BAMI_TEST_TENANT_SYNC_ENABLED'
    }

    It 'requires trusted Tools main for every job, excluding forks, other repositories and non-main refs' {
        $script:variablesJob | Should -Not -BeNullOrEmpty
        foreach ($job in @($script:variablesJob, $script:identitiesJob)) {
            $condition = [regex]::Match($job, '(?ms)^    if: >-\n(.*?)(?=^    runs-on:)').Groups[1].Value
            [regex]::Replace($condition, '\s+', ' ').Trim() | Should -BeExactly (@(
                "github.repository == 'Azure/azure-verified-modules-tools'",
                "github.ref == 'refs/heads/main'"
            ) -join ' && ')
        }
        @([regex]::Matches($script:workflow, '(?m)^    if:')) | Should -HaveCount 2
    }

    It 'uses a separate target-only Variables token in avm without broadening default permissions' {
        $script:workflow | Should -Match '(?m)^permissions:\n  contents: read\n'
        $script:variablesJob | Should -Match '(?m)^    environment: avm$'
        $script:variablesJob | Should -Match '(?m)^          owner: Azure$'
        $script:variablesJob | Should -Match '(?m)^          repositories: bicep-registry-modules$'
        $permissions = @([regex]::Matches($script:variablesJob, '(?m)^          INPUT_PERMISSION-[^\n]+$') | ForEach-Object { $_.Value.Trim() })
        $permissions | Should -Be @('INPUT_PERMISSION-ACTIONS-VARIABLES: write')
        $script:variablesJob | Should -Match 'GH_TOKEN: \$\{\{ steps\.variables-token\.outputs\.token \}\}'
        $script:variablesJob | Should -Not -Match 'steps\.app-token|permission-secrets|permission-contents|permission-pull-requests|permission-workflows|id-token:'
    }

    It 'uses the pinned environment parser without unsupported or broader inputs in <Job>' -ForEach @(
        @{ Job = 'sync-test-tenant-variables' }
        @{ Job = 'sync-module-identities' }
    ) {
        $jobText = if ($Job -ceq 'sync-test-tenant-variables') { $script:variablesJob } else { $script:identitiesJob }
        $tokenSteps = @([regex]::Matches($jobText, '(?ms)^      - name: Create target-scoped Variables token\n.*?(?=^      - |\z)'))
        $tokenSteps | Should -HaveCount 1
        $token = $tokenSteps[0].Value
        $token | Should -Match '(?m)^        id: variables-token$'
        $token | Should -Match '(?m)^        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 '
        $with = [regex]::Match($token, '(?ms)^        with:\n(.*?)(?=^        \S|\z)').Groups[1].Value
        $inputs = @([regex]::Matches($with, '(?m)^          [^\n]+$') | ForEach-Object { $_.Value.Trim() })
        $inputs | Should -Be @(
            'client-id: ${{ vars.AVM_APP_CLIENT_ID }}'
            'private-key: ${{ secrets.AVM_APP_PRIVATE_KEY }}'
            'owner: Azure'
            'repositories: bicep-registry-modules'
        )
        $environment = [regex]::Match($token, '(?ms)^        env:\n(.*?)(?=^        \S|\z)').Groups[1].Value
        $permissionInputs = @([regex]::Matches($environment, '(?m)^          ([^#\s][^:]*): (.+)$'))
        $permissionInputs | Should -HaveCount 1
        $permissionInputs[0].Groups[1].Value | Should -BeExactly 'INPUT_PERMISSION-ACTIONS-VARIABLES'
        $permissionInputs[0].Groups[2].Value | Should -BeExactly 'write'
        $token | Should -Not -Match '(?im)^\s+permission-|skip-token-revoke|ACTIONS_STEP_DEBUG|ACTIONS_RUNNER_DEBUG'
        @([regex]::Matches($script:workflow, '(?m)^          INPUT_PERMISSION-')) | Should -HaveCount 2
    }

    It 'pins both actions and checks out trusted main without persisted credentials' {
        $references = @([regex]::Matches($script:variablesJob, '(?m)^\s+uses: ([^@\s]+)@([^\s]+)'))
        $references | Should -HaveCount 2
        foreach ($reference in $references) { $reference.Groups[2].Value | Should -Match '^[0-9a-f]{40}$' }
        $script:variablesJob | Should -Match '(?s)uses: actions/checkout@[0-9a-f]{40}.*?ref: main\n\s+persist-credentials: false'
        $script:variablesJob | Should -Match '\$env:AVM_APP_SLUG -cne ''azure-verified-modules'''
    }

    It 'enumerates exactly the eight source environment variables, never a secret or environment dump' {
        $names = @([regex]::Matches($script:variablesJob, '(?m)^          (TEST_BAMI_[A-Z_]+): \$\{\{ vars\.\1 \}\}$') | ForEach-Object { $_.Groups[1].Value })
        @($names | Sort-Object) | Should -Be @((New-BicepSyncTestBundle).Keys | Sort-Object)
        $script:variablesJob | Should -Not -Match 'secrets\.TEST_|toJSON\(vars\)|toJSON\(secrets\)'
        foreach ($name in $names) {
            $script:entry | Should -Match ([regex]::Escape("$name = `$env:$name"))
        }
        $script:entry | Should -Not -Match 'Get-ChildItem\s+Env:|GetEnvironmentVariables|Get-Content\s+Env:'
    }

    It 'selects plan or apply through environment data rather than interpolating dispatch input into code' {
        $run = [regex]::Match($script:variablesJob, '(?s)        run: \|\n(.*)$').Groups[1].Value
        $run | Should -Not -BeNullOrEmpty
        $run | Should -Not -Match '\$\{\{'
        $run | Should -Match "'Invoke-BicepTestTenantSync.ps1'\) @options\s*$"
        $run | Should -Match '\$env:BICEP_SYNC_PLAN_ONLY -ceq ''true'''
        $script:entry | Should -Match '\[switch\] \$PlanOnly = \$true'
        $script:entry | Should -Match "Parameter\(Mandatory, ParameterSetName = 'Apply'\)"
    }

    It 'limits OIDC to the identity job and publishes its mapping only after a successful apply' {
        $script:identitiesJob | Should -Match '(?m)^    needs: sync-test-tenant-variables$'
        $script:identitiesJob | Should -Match '(?m)^      id-token: write'
        $script:variablesJob | Should -Not -Match 'id-token:'
        $script:identitiesJob | Should -Match 'repository: Azure/bicep-registry-modules'
        $script:identitiesJob | Should -Match "'Invoke-BicepModuleIdentitySync.ps1'"
        $script:identitiesJob | Should -Match '\-ModuleClientIdPath .* -Apply'
        @([regex]::Matches($script:identitiesJob, "(?m)^        if: github.event_name != 'workflow_dispatch' \|\| !inputs.plan_only$")) |
            Should -HaveCount 2
        $script:identitiesJob | Should -Not -Match 'permission-secrets|permission-contents|permission-workflows|azure/login'
        foreach ($field in @('TENANT_ID', 'SUBSCRIPTION_ID', 'CLIENT_ID', 'STORAGE_ACCOUNT_NAME', 'STORAGE_CONTAINER_NAME')) {
            $script:identitiesJob | Should -Match "ARM_BACKEND_${field}:"
        }
        foreach ($reference in [regex]::Matches($script:identitiesJob, '(?m)^\s+uses: ([^@\s]+)@([^\s]+)')) {
            $reference.Groups[2].Value | Should -Match '^[0-9a-f]{40}$'
        }
    }

    It 'has no selector configuration and reuses the shared bundle validation and process helpers' {
        Test-Path -LiteralPath (Join-Path $script:root 'repository-management' 'bicep-test-tenant-config' 'config.json') | Should -BeFalse
        $script:entry | Should -Not -Match 'Configuration|moduleGroups|TEST_BAMI_MODULE_PATHS'
        $script:entry | Should -Match "'repository-management' 'shared' 'TestTenant.ps1'"
        $script:entry | Should -Match "'RetryHelpers.ps1'"
        $script:entry | Should -Not -Match '\[string\]\s+\$ConfigurationPath|/contents/|/secrets|gh secret|Invoke-WebRequest|Invoke-RestMethod'
        $implementation = Get-Content -LiteralPath (Join-Path $script:syncScripts 'lib' 'TestTenantSync.ps1') -Raw
        $implementation | Should -Match 'Get-AvmBamiSettings -Values \$Values'
        $implementation | Should -Match 'Get-AvmBamiSettings -Values \$bundle -BicepOnly'
        $implementation | Should -Not -Match 'Configuration|moduleGroups|TEST_BAMI_MODULE_PATHS|DeactivationOnly|DeferredValueNames'
        $implementation | Should -Not -Match 'function Get-AvmBamiSettings'
        $shared = Get-Content -LiteralPath (Join-Path $script:root 'repository-management' 'shared' 'TestTenant.ps1') -Raw
        $shared | Should -Not -Match 'Get-AvmBicepModulePath|Convert(To|From)-AvmBicepModulePaths'
    }

    It 'retains serialized workflow writers without cancelling in-flight publication' {
        $script:workflow | Should -Match '(?m)^concurrency:\n  group: bicep-sync\n  cancel-in-progress: false$'
        $script:variablesJob | Should -Not -Match '(?m)^\s+concurrency:'
    }

    It 'keeps the new scripts parseable and LF UTF-8 without BOM' {
        foreach ($path in @(
            (Join-Path $script:syncScripts 'Invoke-BicepTestTenantSync.ps1'),
            (Join-Path $script:syncScripts 'lib' 'GitHubVariables.ps1'),
            (Join-Path $script:syncScripts 'lib' 'TestTenantSync.ps1'),
            (Join-Path $script:root 'repository-management' 'shared' 'TestTenant.ps1'),
            (Join-Path $PSScriptRoot 'BicepTestTenantSync.Tests.ps1'),
            (Join-Path $PSScriptRoot 'TestTenant.Tests.ps1'),
            (Join-Path $script:root 'tests' 'Pester' 'Component' 'BicepTestTenantSync.Component.Tests.ps1')
        )) {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            @($bytes | Where-Object { $_ -eq 13 }) | Should -HaveCount 0
            [System.Convert]::ToHexString($bytes[0..2]) | Should -Not -BeExactly 'EFBBBF'
            $tokens = $null
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors) | Should -HaveCount 0
        }
    }
}
