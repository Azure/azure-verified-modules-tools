BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:syncScripts = Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts'
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:root 'repository-management' 'shared' 'TestTenant.ps1')
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'RetryHelpers.ps1')
    . (Join-Path $script:syncScripts 'lib' 'GitHubVariables.ps1')
    . (Join-Path $script:syncScripts 'lib' 'TestTenantSync.ps1')
    $script:executionNames = @(
        'TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_SUBSCRIPTION_IDS',
        'TEST_BAMI_MANAGEMENT_GROUP_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID'
    )
    $script:selectorName = 'TEST_BAMI_MODULE_PATHS'
    $script:canarySelector = '["avm/res/dev-test-lab/lab"]'
    $script:legacySelector = '[]'

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
        param([string] $Selector = $script:canarySelector)

        foreach ($name in $script:projection.Keys) {
            Set-BicepSyncTestValue -Name $name -Value $script:projection[$name]
        }
        Set-BicepSyncTestValue -Name $script:selectorName -Value $Selector
    }

    function New-BicepSyncApiResponse {
        param([object] $Data, [int] $ExitCode = 0, [string] $StdErr = '')

        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = ConvertTo-Json -InputObject $Data -Depth 10 -Compress; StdErr = $StdErr }
    }

    function New-BicepSyncApiVariable {
        param([string] $Name = 'TEST_BAMI_TENANT_ID', [string] $Value = 'fixture-value')

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
        $script:projection = Get-AvmBamiSettings -Values $script:values -BicepOnly
        $script:configuration = @{ source = 'central-configuration-fixture' }
        $script:desiredSelector = $script:canarySelector
        $script:consumer = [ordered]@{}
        foreach ($variableName in ($script:executionNames + $script:selectorName)) { $script:consumer[$variableName] = $null }
        $script:events = [System.Collections.Generic.List[string]]::new()
        $script:attempts = [System.Collections.Generic.List[object]]::new()
        $script:reads = 0
        $script:onRead = $null
        $script:beforeWrite = $null
        $script:afterWrite = $null
        $script:waits = [System.Collections.Generic.List[int]]::new()
        Mock Start-Sleep { param($Seconds) $script:waits.Add($Seconds) }
        Mock Write-Information {}
        Mock ConvertTo-AvmBicepModulePaths { $script:desiredSelector }
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

    It 'defaults to a read-only plan containing only five execution names and the selector' {
        $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration
        $result.Status | Should -BeExactly 'Planned'
        $result.PlanOnly | Should -BeTrue
        $result.Target | Should -BeExactly 'Azure/bicep-registry-modules'
        $result.DeferredValueNames -is [array] | Should -BeTrue
        $result.DeferredValueNames | Should -HaveCount 0
        @($result.ChangedNames | Sort-Object) | Should -Be @(($script:executionNames + $script:selectorName) | Sort-Object)
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 1
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
        Should -Invoke ConvertTo-AvmBicepModulePaths -Exactly 1 -ParameterFilter {
            [object]::ReferenceEquals($Configuration, $script:configuration)
        }
        $result | ConvertTo-Json -Depth 5 | Should -Not -Match '11111111|22222222|33333333|44444444|55555555|rg-bami-test'
    }

    It 'requires an explicit apply flag rather than accepting PlanOnly false' {
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -PlanOnly:$false } |
            Should -Throw '*Use -Apply explicitly*'
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 0
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'does not write for an explicitly false apply switch or WhatIf' {
        $plan = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply:$false
        $preview = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply -WhatIf
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
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } | Should -Throw
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
        @{ Case = 'management group'; Change = { param($v) $v.TEST_BAMI_MANAGEMENT_GROUP_ID = 'not/a/group' } }
        @{ Case = 'identity resource group'; Change = { param($v) $v.TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME = 'invalid?group' } }
    ) {
        & $Change $script:values
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } | Should -Throw
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 0
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'rejects invalid central configuration before reading or changing the consumer' {
        Mock ConvertTo-AvmBicepModulePaths { throw [System.ArgumentException]::new('Invalid central test tenant configuration.') }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*Invalid central*'
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 0
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'normalizes JSON or native subscription arrays and publishes the selector last' -ForEach @($false, $true) {
        if ($_) { $script:values.TEST_BAMI_SUBSCRIPTION_IDS = $script:values.TEST_BAMI_SUBSCRIPTION_IDS | ConvertTo-Json -Depth 5 }
        $script:beforeWrite = {
            param($Name)
            if ($Name -ceq $script:selectorName) {
                foreach ($key in $script:projection.Keys) {
                    $script:consumer[$key].Value | Should -BeExactly $script:projection[$key]
                }
            }
        }
        $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply
        $result.Status | Should -BeExactly 'Published'
        $result.PlanOnly | Should -BeFalse
        $script:attempts | Should -HaveCount 6
        @($script:attempts.Name | Sort-Object) | Should -Be @(($script:executionNames + $script:selectorName) | Sort-Object)
        @($script:attempts.Name) | Should -Not -Contain 'TEST_BAMI_CONTROLLER_CLIENT_ID'
        @($script:attempts.Name) | Should -Not -Contain 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID'
        @($script:attempts.Name) | Should -Not -Contain 'TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME'
        $script:attempts[-1].Name | Should -BeExactly $script:selectorName
        $script:consumer[$script:selectorName].Value | Should -BeExactly $script:canarySelector
        $subscriptions = $script:consumer.TEST_BAMI_SUBSCRIPTION_IDS.Value
        @($subscriptions | ConvertFrom-Json) | Should -HaveCount 28
        $subscriptions | Should -Not -Match '\r|\n'
        $selectorWrite = $script:events.IndexOf("write:$script:selectorName")
        @($script:events[($selectorWrite - 3)..($selectorWrite - 1)] | Where-Object { $_ -like 'read:*' }) | Should -HaveCount 3
        @($script:events[($selectorWrite + 1)..($script:events.Count - 1)] | Where-Object { $_ -like 'read:*' }) | Should -HaveCount 2
        @($script:attempts.Method | Select-Object -Unique) | Should -Be @('POST')
    }

    It 'returns a no-op for an unchanged active candidate without touching any values' {
        Initialize-BicepSyncTestCandidate
        $script:values.TEST_BAMI_CONTROLLER_CLIENT_ID = '77777777-7777-4777-8777-777777777777'
        $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply
        $result.Status | Should -BeExactly 'NoChange'
        $result.HasChanges | Should -BeFalse
        $result.ChangedNames | Should -HaveCount 0
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 3
    }

    It 'is a no-op on a second identical apply and does not patch already-equal values' {
        $first = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply
        $second = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply
        $first.Status | Should -BeExactly 'Published'
        $second.Status | Should -BeExactly 'NoChange'
        $script:attempts | Should -HaveCount 6
    }

    Context 'Acknowledged write readback visibility' {
        BeforeEach {
            Initialize-BicepSyncTestCandidate -Selector $script:legacySelector
            $script:visibilityName = 'TEST_BAMI_SUBSCRIPTION_IDS'
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
            $result[$script:selectorName].Value | Should -BeExactly $script:legacySelector
            $script:attempts | Should -HaveCount 1
            $script:attempts[0].Method | Should -BeExactly $Method
            $script:waits | Should -Be @(1..$StaleReads | ForEach-Object { 5 * $_ })
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly ($StaleReads + 2)
            Should -Invoke Write-Information -Exactly $StaleReads -ParameterFilter {
                $MessageData -clike '*readback visibility of TEST_BAMI_SUBSCRIPTION_IDS; retrying only the GET, not the acknowledged write.'
            }
        }

        It 'stops after four stale readbacks and 30 seconds of waits without publishing the selector or rolling back' {
            $script:staleReads = 4
            { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
                Should -Throw '*Readback mismatch after writing TEST_BAMI_SUBSCRIPTION_IDS*after 4 readback attempt*'
            $script:waits | Should -Be @(5, 10, 15)
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 6
            @($script:attempts.Name) | Should -Be @($script:visibilityName)
            $script:consumer[$script:visibilityName].Value | Should -BeExactly $script:projection[$script:visibilityName]
            $script:consumer[$script:selectorName].Value | Should -BeExactly $script:legacySelector
        }

        It 'stops on a changed <Name> during a later readback without waiting again' -ForEach @(
            @{ Name = 'TEST_BAMI_TENANT_ID' }
            @{ Name = 'TEST_BAMI_MODULE_PATHS' }
            @{ Name = 'TEST_BAMI_SUBSCRIPTION_IDS' }
        ) {
            $script:driftName = $Name
            $script:onRead = {
                param($Read)
                if ($Read -eq 4) {
                    Set-BicepSyncTestValue -Name $script:driftName -Value 'outside-value' -Revision 'outside'
                }
            }
            { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
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
            { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
                Should -Throw '*Readback mismatch after writing*'
            Should -Invoke Start-Sleep -Exactly 0
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 3
            $script:attempts | Should -HaveCount 1
        }

        It 'fails immediately if a later visibility GET fails' {
            $script:onRead = {
                param($Read)
                if ($Read -eq 4) { throw [System.IO.IOException]::new('Readback unavailable.') }
            }
            { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
                Should -Throw '*was acknowledged, and consumer readback failed*outcome is unverified*'
            $script:waits | Should -Be @(5)
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 4
            $script:attempts | Should -HaveCount 1
            $script:consumer[$script:selectorName].Value | Should -BeExactly $script:legacySelector
        }

        It 'never waits or retries an unacknowledged write with <StaleReads> stale reads' -ForEach @(
            @{ StaleReads = 0 }
            @{ StaleReads = 1 }
        ) {
            $script:staleReads = $StaleReads
            $script:afterWrite = { throw [System.TimeoutException]::new('Response lost.') }
            { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
                Should -Throw '*was not acknowledged*No write retry or rollback was attempted*'
            Should -Invoke Start-Sleep -Exactly 0
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 3
            $script:attempts | Should -HaveCount 1
            $script:consumer[$script:selectorName].Value | Should -BeExactly $script:legacySelector
        }

        It 'verifies the complete bundle after an acknowledged selector becomes visible' {
            Initialize-BicepSyncTestCandidate -Selector $script:legacySelector
            $script:visibilityName = $script:selectorName
            $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply
            $result.Status | Should -BeExactly 'Published'
            $script:waits | Should -Be @(5)
            Should -Invoke Get-AvmBicepTestTenantSnapshot -Exactly 6
            @($script:attempts.Name) | Should -Be @($script:selectorName)
            foreach ($name in $script:projection.Keys) {
                $script:consumer[$name].Value | Should -BeExactly $script:projection[$name]
            }
        }
    }

    It 'refuses each changed active execution value until a separate deactivation: <Name>' -ForEach @(
        @{ Name = 'TEST_BAMI_TENANT_ID'; Value = '77777777-7777-4777-8777-777777777777' }
        @{ Name = 'TEST_BAMI_BICEP_CLIENT_ID'; Value = '77777777-7777-4777-8777-777777777777' }
        @{ Name = 'TEST_BAMI_SUBSCRIPTION_IDS'; Value = 'subscriptions' }
        @{ Name = 'TEST_BAMI_MANAGEMENT_GROUP_ID'; Value = 'other-bami-group' }
        @{ Name = 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID'; Value = '77777777-7777-4777-8777-777777777777' }
    ) {
        Initialize-BicepSyncTestCandidate
        if ($Name -ceq 'TEST_BAMI_SUBSCRIPTION_IDS') {
            $script:values[$Name][0].id = '77777777-7777-4777-8777-777777777777'
        }
        else { $script:values[$Name] = $Value }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*Active BAMI execution values cannot change*Separately deactivate*'
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        $script:consumer[$script:selectorName].Value | Should -BeExactly $script:canarySelector
    }

    It 'also refuses planning an unsafe active retarget instead of producing an applicable plan' {
        Initialize-BicepSyncTestCandidate
        $script:values.TEST_BAMI_TENANT_ID = '77777777-7777-4777-8777-777777777777'
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration } |
            Should -Throw '*Active BAMI*'
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'permits a selector-only change when the active execution bundle is unchanged' {
        Initialize-BicepSyncTestCandidate
        $script:desiredSelector = '["avm/res/storage/storage-account"]'
        $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply
        $result.Status | Should -BeExactly 'Published'
        @($script:attempts.Name) | Should -Be @($script:selectorName)
        $script:attempts[0].Method | Should -BeExactly 'PATCH'
    }

    It 'treats blank and empty lists as inactive before publishing a new selection' -ForEach @('', '[]') {
        Initialize-BicepSyncTestCandidate -Selector $_
        $script:values.TEST_BAMI_TENANT_ID = '77777777-7777-4777-8777-777777777777'
        $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply
        $result.Status | Should -BeExactly 'Published'
        @($script:attempts.Name) | Should -Be @('TEST_BAMI_TENANT_ID', $script:selectorName)
        $script:consumer[$script:selectorName].Value | Should -BeExactly $script:canarySelector
    }

    It 'deactivates without changing active values, then permits retargeting in a later inactive run' {
        Initialize-BicepSyncTestCandidate
        $initial = Copy-BicepSyncTestSnapshot -Snapshot $script:consumer
        $script:desiredSelector = $script:legacySelector
        $script:values.TEST_BAMI_TENANT_ID = '77777777-7777-4777-8777-777777777777'
        $deactivated = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply
        $deactivated.Status | Should -BeExactly 'Deactivated'
        $deactivated.DeactivationOnly | Should -BeTrue
        $deactivated.DeferredValueNames -is [array] | Should -BeTrue
        @($deactivated.DeferredValueNames) | Should -Be @('TEST_BAMI_TENANT_ID')
        @($script:attempts.Name) | Should -Be @($script:selectorName)
        foreach ($name in $script:executionNames) {
            $script:consumer[$name].Value | Should -BeExactly $initial[$name].Value
            $script:consumer[$name].UpdatedAt | Should -BeExactly $initial[$name].UpdatedAt
        }
        $retargeted = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply
        $retargeted.Status | Should -BeExactly 'Published'
        @($script:attempts.Name) | Should -Be @($script:selectorName, 'TEST_BAMI_TENANT_ID')
        $script:consumer.TEST_BAMI_TENANT_ID.Value | Should -BeExactly $script:values.TEST_BAMI_TENANT_ID
        $script:consumer[$script:selectorName].Value | Should -BeExactly $script:legacySelector
    }

    It 'allows selector-only deactivation even when the existing candidate is incomplete' {
        Initialize-BicepSyncTestCandidate
        $script:consumer.TEST_BAMI_BICEP_CLIENT_ID = $null
        $script:desiredSelector = $script:legacySelector
        $result = Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply
        $result.Status | Should -BeExactly 'Deactivated'
        @($script:attempts.Name) | Should -Be @($script:selectorName)
        $script:consumer.TEST_BAMI_BICEP_CLIENT_ID | Should -BeNullOrEmpty
    }

    It 'rejects malformed existing routing even for an all-legacy request' -ForEach @(
        '{', '{}', 'null', '[null]',
        '"avm/res/dev-test-lab/lab"',
        '["avm/res/dev-test-lab/lab",false]',
        '["avm/res/dev-test-lab/*"]',
        '["avm/res/Dev-test-lab/lab"]'
    ) {
        Set-BicepSyncTestValue -Name $script:selectorName -Value $_
        $script:desiredSelector = $script:legacySelector
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } | Should -Throw
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'stops on first and late write failures without retry, rollback, or selector publication' -ForEach @(0, 4) {
        $script:failedName = @($script:projection.Keys)[$_]
        $script:beforeWrite = {
            param($Name)
            if ($Name -ceq $script:failedName) { throw [System.IO.IOException]::new('Write failed.') }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*not acknowledged*Readback does not match*'
        $script:attempts | Should -HaveCount ($_ + 1)
        @($script:attempts | Where-Object Name -CEQ $script:failedName) | Should -HaveCount 1
        $script:consumer[$script:failedName] | Should -BeNullOrEmpty
        $script:consumer[$script:selectorName] | Should -BeNullOrEmpty
        @($script:attempts.Name) | Should -Not -Contain $script:selectorName
        foreach ($attempt in @($script:attempts | Where-Object Name -CNE $script:failedName)) {
            $script:consumer[$attempt.Name].Value | Should -BeExactly $attempt.Value
        }
    }

    It 'verifies successful candidate writes with lost responses, then fails without activating' -ForEach @(0, 4) {
        $script:failedName = @($script:projection.Keys)[$_]
        $script:afterWrite = {
            param($Name)
            if ($Name -ceq $script:failedName) { throw [System.TimeoutException]::new('Response lost.') }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*not acknowledged*Readback confirms the requested candidate value is present and the selector is unchanged*'
        $script:attempts | Should -HaveCount ($_ + 1)
        $script:consumer[$script:failedName].Value | Should -BeExactly $script:projection[$script:failedName]
        $script:consumer[$script:selectorName] | Should -BeNullOrEmpty
        $script:events[-1] | Should -BeLike 'read:*'
    }

    It 'leaves successful candidate writes intact when the selector request fails' {
        $script:beforeWrite = {
            param($Name)
            if ($Name -ceq $script:selectorName) { throw [System.IO.IOException]::new('Selector write failed.') }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*not acknowledged*Readback does not match*TEST_BAMI_MODULE_PATHS*'
        $script:attempts | Should -HaveCount 6
        $script:consumer[$script:selectorName] | Should -BeNullOrEmpty
        foreach ($name in $script:executionNames) {
            $script:consumer[$name].Value | Should -BeExactly $script:projection[$name]
        }
    }

    It 'verifies a lost selector response and truthfully reports that routing may already be active' {
        $script:afterWrite = {
            param($Name)
            if ($Name -ceq $script:selectorName) { throw [System.TimeoutException]::new('Selector response lost.') }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*Readback confirms the requested selector and unchanged execution values are present; routing may already be active*'
        $script:attempts | Should -HaveCount 6
        $script:consumer[$script:selectorName].Value | Should -BeExactly $script:canarySelector
        $script:events[-1] | Should -BeLike 'read:*'
    }

    It 'reports unknown outcomes when write readback fails: <Stage>, lost response <Lost>' -ForEach @(
        @{ Stage = 'value'; Lost = $false }
        @{ Stage = 'value'; Lost = $true }
        @{ Stage = 'selector'; Lost = $false }
        @{ Stage = 'selector'; Lost = $true }
    ) {
        $script:failedName = if ($Stage -ceq 'selector') { $script:selectorName } else { @($script:projection.Keys)[0] }
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
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } | Should -Throw $expected
        @($script:attempts | Where-Object Name -CEQ $script:failedName) | Should -HaveCount 1
        $script:consumer[$script:failedName] | Should -Not -BeNullOrEmpty
    }

    It 'detects a mismatching acknowledged write and preserves the observed value without rollback' -ForEach @(0, 4) {
        $script:failedName = @($script:projection.Keys)[$_]
        $script:afterWrite = {
            param($Name)
            if ($Name -ceq $script:failedName) { Set-BicepSyncTestValue -Name $Name -Value 'outside-value' -Revision 'outside' }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*Readback mismatch after writing*'
        $script:consumer[$script:failedName].Value | Should -BeExactly 'outside-value'
        $script:consumer[$script:selectorName] | Should -BeNullOrEmpty
        $script:attempts | Should -HaveCount ($_ + 1)
    }

    It 'does not overwrite an outside edit found before the first write' {
        $script:onRead = {
            param($Read)
            if ($Read -eq 2) { Set-BicepSyncTestValue -Name 'TEST_BAMI_TENANT_ID' -Value 'outside-value' -Revision 'outside' }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*changed outside this sync during pre-write*'
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
        $script:consumer.TEST_BAMI_TENANT_ID.Value | Should -BeExactly 'outside-value'
    }

    It 'detects outside changes between writes before overwriting the next planned value' {
        $script:nextName = @($script:projection.Keys)[1]
        $script:onRead = {
            param($Read)
            if ($Read -eq 4) { Set-BicepSyncTestValue -Name $script:nextName -Value 'outside-value' -Revision 'outside' }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*changed outside this sync during pre-write*'
        $script:attempts | Should -HaveCount 1
        $script:consumer[$script:nextName].Value | Should -BeExactly 'outside-value'
        $script:consumer[$script:selectorName] | Should -BeNullOrEmpty
    }

    It 'detects an outside selector activation during a value write without automatically disabling it' {
        $script:afterWrite = {
            Set-BicepSyncTestValue -Name $script:selectorName -Value $script:canarySelector -Revision 'outside'
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*This run did not write the selector*Readback mismatch*TEST_BAMI_MODULE_PATHS*'
        $script:attempts | Should -HaveCount 1
        $script:consumer[$script:selectorName].Value | Should -BeExactly $script:canarySelector
    }

    It 'detects drift at the complete readback, immediately before the selector, and after publication' -ForEach @(
        @{ Read = 2; ExpectedWrites = 0; Stage = 'complete execution-value readback' }
        @{ Read = 3; ExpectedWrites = 0; Stage = 'pre-write TEST_BAMI_MODULE_PATHS' }
        @{ Read = 5; ExpectedWrites = 1; Stage = 'final publication readback' }
    ) {
        Initialize-BicepSyncTestCandidate -Selector $script:legacySelector
        $script:driftRead = $Read
        $script:onRead = {
            param($Read)
            if ($Read -eq $script:driftRead) {
                Set-BicepSyncTestValue -Name 'TEST_BAMI_BICEP_CLIENT_ID' -Value 'outside-value' -Revision 'outside'
            }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw "*changed outside this sync during ${Stage}*"
        $script:attempts | Should -HaveCount $ExpectedWrites
        $script:consumer.TEST_BAMI_BICEP_CLIENT_ID.Value | Should -BeExactly 'outside-value'
        if ($ExpectedWrites -eq 1) {
            $script:consumer[$script:selectorName].Value | Should -BeExactly $script:canarySelector
        }
    }

    It 'detects metadata-only edits even when candidate values remain identical' -ForEach @('CreatedAt', 'UpdatedAt') {
        Initialize-BicepSyncTestCandidate -Selector $script:legacySelector
        $script:changedField = $_
        $script:onRead = {
            param($Read)
            if ($Read -eq 3) { $script:consumer.TEST_BAMI_TENANT_ID.($script:changedField) = 'outside' }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*changed outside this sync*TEST_BAMI_TENANT_ID*'
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
    }

    It 'detects deletion and recreation of the variable being patched' {
        Initialize-BicepSyncTestCandidate -Selector $script:legacySelector
        $script:values.TEST_BAMI_TENANT_ID = '77777777-7777-4777-8777-777777777777'
        $script:afterWrite = {
            param($Name)
            $script:consumer[$Name].CreatedAt = 'outside-recreation'
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*Readback mismatch*TEST_BAMI_TENANT_ID*'
        $script:attempts | Should -HaveCount 1
        $script:consumer.TEST_BAMI_TENANT_ID.CreatedAt | Should -BeExactly 'outside-recreation'
        $script:consumer[$script:selectorName].Value | Should -BeExactly $script:legacySelector
        Should -Invoke Start-Sleep -Exactly 0
    }

    It 'does not clobber an outside selector edit after its own selector write' {
        Initialize-BicepSyncTestCandidate -Selector $script:legacySelector
        $script:afterWrite = {
            param($Name)
            if ($Name -ceq $script:selectorName) { Set-BicepSyncTestValue -Name $Name -Value $script:legacySelector -Revision 'outside' }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*Readback mismatch*TEST_BAMI_MODULE_PATHS*'
        $script:attempts | Should -HaveCount 1
        $script:consumer[$script:selectorName].Value | Should -BeExactly $script:legacySelector
    }

    It 'detects a changed consumer during no-op verification instead of reporting success' {
        Initialize-BicepSyncTestCandidate
        $script:onRead = {
            param($Read)
            if ($Read -eq 2) { $script:consumer.TEST_BAMI_TENANT_ID = $null }
        }
        { Invoke-AvmBicepTestTenantSync -Values $script:values -Configuration $script:configuration -Apply } |
            Should -Throw '*changed outside this sync*'
        Should -Invoke Invoke-AvmBicepTestTenantVariableApi -Exactly 0
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
        $payload = '[]'
        $null = Invoke-AvmBicepTestTenantVariableApi -Method $_ -Name 'TEST_BAMI_MODULE_PATHS' -Value $payload
        $script:expectedMethod = $_
        $script:expectedEndpoint = 'repos/Azure/bicep-registry-modules/actions/variables'
        if ($_ -ceq 'PATCH') { $script:expectedEndpoint += '/TEST_BAMI_MODULE_PATHS' }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter {
            $Arguments[4] -ceq $script:expectedMethod -and $Arguments[11] -ceq $script:expectedEndpoint -and
            $Arguments[12] -ceq '--raw-field' -and $Arguments[13] -ceq 'name=TEST_BAMI_MODULE_PATHS' -and
            $Arguments[14] -ceq '--raw-field' -and $Arguments[15] -ceq 'value=[]' -and
            $Arguments.Count -eq 16 -and ($Arguments -join '|') -cnotmatch 'fixture-installation-token|/secrets'
        }
    }

    It 'never falls back or retries when GitHub refuses access or returns a transient failure' -ForEach @(403, 404, 500) {
        $script:response = New-BicepSyncApiResponse -Data @{} -ExitCode 1 -StdErr "sensitive-diagnostic-sentinel (HTTP $_)"
        { Get-AvmBicepTestTenantSnapshot } | Should -Throw "*HTTP $_*"
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1
        $caught = $null
        try { Invoke-AvmBicepTestTenantVariableApi -Method 'PATCH' -Name 'TEST_BAMI_TENANT_ID' -Value 'fixture-value' }
        catch { $caught = $_.Exception.Message }
        $caught | Should -Not -BeNullOrEmpty
        $caught | Should -Not -Match 'sensitive-diagnostic-sentinel'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 2
    }

    It 'rejects legacy, controller, administration, secret, and noncanonical names' -ForEach @(
        'ARM_TENANT_ID', 'TEST_BAMI_CONTROLLER_CLIENT_ID', 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID',
        'TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME', 'GH_TOKEN', 'test_bami_tenant_id', '../secrets/ANY'
    ) {
        { Invoke-AvmBicepTestTenantVariableApi -Method 'POST' -Name $_ -Value 'fixture-value' } | Should -Throw
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'refuses invalid request combinations and never deletes variables' {
        { Invoke-AvmBicepTestTenantVariableApi -Method 'DELETE' -Name 'TEST_BAMI_TENANT_ID' } | Should -Throw
        { Invoke-AvmBicepTestTenantVariableApi -Method 'POST' -Name 'TEST_BAMI_TENANT_ID' } | Should -Throw '*explicit value*'
        { Invoke-AvmBicepTestTenantVariableApi -Method 'POST' -Name 'TEST_BAMI_TENANT_ID' -Value 'value' -Page 1 } | Should -Throw '*pagination*'
        { Invoke-AvmBicepTestTenantVariableApi -Name 'TEST_BAMI_TENANT_ID' } | Should -Throw '*collection*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'requires an explicit installation token and honors offline mode and WhatIf' {
        $env:GH_TOKEN = ''
        { Invoke-AvmBicepTestTenantVariableApi } | Should -Throw '*explicit target-scoped*'
        $env:GH_TOKEN = 'fixture-installation-token'
        $env:AVM_OFFLINE = '1'
        { Invoke-AvmBicepTestTenantVariableApi } | Should -Throw '*AVM_OFFLINE=1*'
        $env:AVM_OFFLINE = '0'
        { Invoke-AvmBicepTestTenantVariableApi -Method 'POST' -Name 'TEST_BAMI_TENANT_ID' -Value 'value' -WhatIf } |
            Should -Throw '*not approved*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'snapshots only the six relevant variables and retains their timestamps without logging values' {
        $script:response = New-BicepSyncApiResponse -Data @{
            total_count = 3
            variables = @(
                (New-BicepSyncApiVariable),
                (New-BicepSyncApiVariable -Name 'ARM_TENANT_ID' -Value 'legacy-value'),
                (New-BicepSyncApiVariable -Name 'TEST_BAMI_CONTROLLER_CLIENT_ID' -Value 'controller-value')
            )
        }
        $snapshot = Get-AvmBicepTestTenantSnapshot
        $snapshot.Count | Should -Be 6
        $snapshot.TEST_BAMI_TENANT_ID.Value | Should -BeExactly 'fixture-value'
        $snapshot.TEST_BAMI_TENANT_ID.CreatedAt | Should -BeExactly '2026-09-01T00:00:00.0000000Z'
        $snapshot.TEST_BAMI_TENANT_ID.UpdatedAt | Should -BeExactly '2026-09-15T00:00:00.0000000Z'
        $snapshot.Contains('ARM_TENANT_ID') | Should -BeFalse
        $snapshot.Contains('TEST_BAMI_CONTROLLER_CLIENT_ID') | Should -BeFalse
        $snapshot.TEST_BAMI_MODULE_PATHS | Should -BeNullOrEmpty
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
        @{ Case = 'noncanonical candidate name'; Data = @{ total_count = 1; variables = @(@{ name = 'test_bami_tenant_id'; value = 'value' }) } }
        @{ Case = 'missing candidate value'; Data = @{ total_count = 1; variables = @(@{ name = 'TEST_BAMI_TENANT_ID' }) } }
        @{ Case = 'missing timestamp'; Data = @{ total_count = 1; variables = @(@{ name = 'TEST_BAMI_TENANT_ID'; value = 'value' }) } }
        @{ Case = 'invalid timestamp'; Data = @{ total_count = 1; variables = @(@{ name = 'TEST_BAMI_TENANT_ID'; value = 'value'; created_at = 'not-a-date'; updated_at = 'not-a-date' }) } }
    ) {
        $script:response = New-BicepSyncApiResponse -Data $Data
        { Get-AvmBicepTestTenantSnapshot } | Should -Throw
    }

    It 'reads every page before treating a candidate or selector as absent' {
        $script:firstPage = @(1..99 | ForEach-Object { @{ name = "LEGACY_$_" } })
        $script:firstPage += New-BicepSyncApiVariable
        Mock Invoke-RepositorySyncProcess {
            param($Arguments)
            if ($Arguments[11] -clike '*page=1') {
                return New-BicepSyncApiResponse -Data @{ total_count = 101; variables = $script:firstPage }
            }
            New-BicepSyncApiResponse -Data @{
                total_count = 101
                variables = @((New-BicepSyncApiVariable -Name 'TEST_BAMI_MODULE_PATHS' -Value $script:legacySelector))
            }
        }
        $snapshot = Get-AvmBicepTestTenantSnapshot
        $snapshot.TEST_BAMI_TENANT_ID.Value | Should -BeExactly 'fixture-value'
        $snapshot.TEST_BAMI_MODULE_PATHS.Value | Should -BeExactly $script:legacySelector
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
        $null = Invoke-AvmBicepTestTenantVariableApi -Method 'PATCH' -Name 'TEST_BAMI_MODULE_PATHS' -Value $script:legacySelector
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            [System.IO.Path]::IsPathRooted($FilePath) -and $ArgumentList -is [string[]] -and
            $ArgumentList[15] -ceq 'value=[]' -and
            $EnvVars.GH_TOKEN -ceq 'fixture-installation-token' -and $EnvVars.GH_HOST -ceq 'github.com' -and
            $null -eq $EnvVars.GITHUB_TOKEN -and $null -eq $EnvVars.GH_DEBUG -and
            $EnvVars.GH_PROMPT_DISABLED -ceq '1' -and $IgnoreExitCode -and -not $StreamOutput -and $TimeoutSec -eq 60
        }
    }
}

Describe 'Bicep workflow isolation and trusted input boundary' {
    BeforeAll {
        $script:workflow = (Get-Content -LiteralPath (Join-Path $script:root '.github' 'workflows' 'repository-management-bicep-sync.yml') -Raw).Replace("`r`n", "`n")
        $script:variablesJob = [regex]::Match($script:workflow, '(?ms)^  sync-test-tenant-variables:\n.*\z').Value
        $script:entry = Get-Content -LiteralPath (Join-Path $script:syncScripts 'Invoke-BicepTestTenantSync.ps1') -Raw
    }

    It 'runs only the variable job and never restores Bicep CODEOWNERS publication' {
        $jobs = @([regex]::Matches($script:workflow, '(?m)^  ([a-z][a-z-]+):\n    name:') |
            ForEach-Object { $_.Groups[1].Value })
        $jobs | Should -Be @('sync-test-tenant-variables')
        $script:workflow | Should -Not -Match 'BicepCodeownersSync|bicep-codeowners-sync|Generate and synchronize CODEOWNERS'
        Test-Path -LiteralPath (Join-Path $script:root 'repository-management' 'bicep-codeowners-sync') | Should -BeFalse
    }

    It 'restores the previous schedule and input-free dispatch without activation or preview flags' {
        $triggers = [regex]::Match($script:workflow, '(?ms)^on:\n(.*?)(?=^\S)').Groups[1].Value.TrimEnd()
        $triggers | Should -BeExactly (@(
            '  schedule:'
            "    - cron: '33 2-23/4 * * *'"
            '  workflow_dispatch:'
        ) -join "`n")
        $script:workflow | Should -Not -Match 'inputs[.:]|enable_test_tenant_sync|plan_only|PlanOnly|WhatIf|AVM_BAMI_TEST_TENANT_SYNC_ENABLED'
    }

    It 'requires trusted Tools main for every job, excluding forks, other repositories and non-main refs' {
        $script:variablesJob | Should -Not -BeNullOrEmpty
        $condition = [regex]::Match($script:variablesJob, '(?ms)^    if: >-\n(.*?)(?=^    runs-on:)').Groups[1].Value
        [regex]::Replace($condition, '\s+', ' ').Trim() | Should -BeExactly (@(
            "github.repository == 'Azure/azure-verified-modules-tools'",
            "github.ref == 'refs/heads/main'"
        ) -join ' && ')
        @([regex]::Matches($script:workflow, '(?m)^\s+if:')) | Should -HaveCount 1
    }

    It 'uses a separate target-only Variables token in avm without broadening default permissions' {
        $script:workflow | Should -Match '(?m)^permissions:\n  contents: read\n'
        $script:variablesJob | Should -Match '(?m)^    environment: avm$'
        $script:variablesJob | Should -Match '(?m)^          owner: Azure$'
        $script:variablesJob | Should -Match '(?m)^          repositories: bicep-registry-modules$'
        $permissions = @([regex]::Matches($script:variablesJob, '(?m)^          permission-[^\n]+$') | ForEach-Object { $_.Value.Trim() })
        $permissions | Should -Be @('permission-actions-variables: write')
        $script:variablesJob | Should -Match 'GH_TOKEN: \$\{\{ steps\.variables-token\.outputs\.token \}\}'
        $script:variablesJob | Should -Not -Match 'steps\.app-token|permission-secrets|permission-contents|permission-pull-requests|permission-workflows|id-token:'
    }

    It 'uses the pinned action with only the intended Variables token inputs' {
        $tokenSteps = @([regex]::Matches($script:variablesJob, '(?ms)^      - name: Create target-scoped Variables token\n.*?(?=^      - |\z)'))
        $tokenSteps | Should -HaveCount 1
        $token = $tokenSteps[0].Value
        $token | Should -Match '(?m)^        id: variables-token$'
        $token | Should -Match '(?m)^        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 '
        $inputs = @([regex]::Matches($token, '(?m)^          [^\n]+$') | ForEach-Object { $_.Value.Trim() })
        $inputs | Should -Be @(
            'client-id: ${{ vars.AVM_APP_CLIENT_ID }}'
            'private-key: ${{ secrets.AVM_APP_PRIVATE_KEY }}'
            'owner: Azure'
            'repositories: bicep-registry-modules'
            'permission-actions-variables: write'
        )
        $script:workflow | Should -Not -Match '(?m)^\s+permission-variables:'
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

    It 'calls Apply directly without dispatch input interpolation and retains standalone previews' {
        $run = [regex]::Match($script:variablesJob, '(?s)        run: \|\n(.*)$').Groups[1].Value
        $run | Should -Not -BeNullOrEmpty
        $run | Should -Not -Match '\$\{\{'
        $run | Should -Match "'Invoke-BicepTestTenantSync.ps1'\) -Apply\s*$"
        $script:entry | Should -Match '\[switch\] \$PlanOnly = \$true'
        $script:entry | Should -Match "Parameter\(Mandatory, ParameterSetName = 'Apply'\)"
    }

    It 'derives selection from the central tools config and reuses the shared validation and process helpers' {
        $script:entry | Should -Match "'repository-management' 'bicep-test-tenant-config' 'config.json'"
        $script:entry | Should -Match "'repository-management' 'shared' 'TestTenant.ps1'"
        $script:entry | Should -Match "'RetryHelpers.ps1'"
        $script:entry | Should -Not -Match '\[string\]\s+\$ConfigurationPath|/contents/|/secrets|gh secret|Invoke-WebRequest|Invoke-RestMethod'
        $implementation = Get-Content -LiteralPath (Join-Path $script:syncScripts 'lib' 'TestTenantSync.ps1') -Raw
        $implementation | Should -Match 'Get-AvmBamiSettings -Values \$Values'
        $implementation | Should -Match 'Get-AvmBamiSettings -Values \$bundle -BicepOnly'
        $implementation | Should -Match 'ConvertTo-AvmBicepModulePaths -Configuration \$Configuration'
        $implementation | Should -Match 'ConvertFrom-AvmBicepModulePaths -Json \$existingSelector'
        $implementation | Should -Not -Match 'function (Get-AvmBamiSettings|ConvertTo-AvmBicepModulePaths|ConvertFrom-AvmBicepModulePaths)'
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
