#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep reserved subscription contract' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:root
        $script:path = Join-Path $script:root '.reserved-test-subscriptions.json'
        $script:modulePath = 'avm/res/azure-stack-hci/cluster'
        $script:map = '{"avm/res/azure-stack-hci/cluster":"Azure Local"}'
        [IO.File]::WriteAllText($script:path, $script:map)
        $script:pool = @(
            @{ name = 'reserved'; id = 'ABCDEF01-ABCD-4ABC-8ABC-ABCDEF012345'; tag = 'Azure Local' }
            @{ name = 'historical'; id = '00000000-0000-4000-8000-000000000002' }
            @{ name = 'ordinary'; id = '00000000-0000-4000-8000-000000000003'; tag = 'General' }
        )
    }

    It 'selects the exact mapped tag while retaining original index, ID spelling and canonical SHA-256 key' {
        InModuleScope Avm.Authoring -Parameters @{
            Root = $script:root; ModulePath = $script:modulePath
            Json = (ConvertTo-Json -InputObject $script:pool -Compress)
        } {
            param($Root, $ModulePath, $Json)
            $selected = Select-AvmBicepWorkflowSubscription -PoolJson $Json `
                -RepositoryRoot $Root -ModulePath $ModulePath -RandomSeed 123 -CaseIndex 7
            $selected.SubscriptionId | Should -BeExactly 'ABCDEF01-ABCD-4ABC-8ABC-ABCDEF012345'
            $selected.Tag | Should -BeExactly 'Azure Local'
            $selected.Index | Should -Be 0
            $bytes = [Text.Encoding]::UTF8.GetBytes('abcdef01-abcd-4abc-8abc-abcdef012345')
            $selected.Key | Should -BeExactly ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant())
            $selected.Key | Should -Match '\A[0-9a-f]{64}\z'
        }
    }

    It 'keeps General selection balanced without renumbering the filtered records' {
        InModuleScope Avm.Authoring -Parameters @{ Json = (ConvertTo-Json -InputObject $script:pool -Compress) } {
            param($Json)
            $selected = @(0..5 | ForEach-Object {
                    Select-AvmBicepWorkflowSubscription -PoolJson $Json -RandomSeed 123 -CaseIndex $_
                })
            @($selected.Tag | Select-Object -Unique) | Should -Be @('General')
            @($selected.Index | Sort-Object -Unique) | Should -Be @(1, 2)
            $selected[0].SubscriptionId | Should -Be $selected[2].SubscriptionId
            $selected[1].SubscriptionId | Should -Be $selected[3].SubscriptionId
        }
    }

    It 'does not inherit a reservation for a child, parent or related root: <ModulePath>' -ForEach @(
        @{ ModulePath = 'avm/res/azure-stack-hci/cluster/child' }
        @{ ModulePath = 'avm/res/azure-stack-hci/logical-network' }
        @{ ModulePath = 'avm/res/hybrid-compute/machine' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; ModulePath = $ModulePath } {
            param($Root, $ModulePath)
            Get-AvmBicepTestSubscriptionTag -RepositoryRoot $Root -ModulePath $ModulePath | Should -BeExactly 'General'
        }
    }

    It 'does not inherit a child reservation when its parent is selected' {
        [IO.File]::WriteAllText($script:path, '{"avm/res/azure-stack-hci/cluster/child":"Azure Local"}')
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; ModulePath = $script:modulePath } {
            param($Root, $ModulePath)
            Get-AvmBicepTestSubscriptionTag -RepositoryRoot $Root -ModulePath $ModulePath | Should -BeExactly 'General'
        }
    }

    It 'accepts an empty map and the exact 64-KiB byte limit' {
        [IO.File]::WriteAllText($script:path, '{}' + (' ' * (64KB - 2)))
        (Get-Item -LiteralPath $script:path).Length | Should -Be 64KB
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; ModulePath = $script:modulePath } {
            param($Root, $ModulePath)
            Get-AvmBicepTestSubscriptionTag -RepositoryRoot $Root -ModulePath $ModulePath | Should -BeExactly 'General'
        }
    }

    It 'rejects an invalid module path without trimming, folding or separator normalization: <ModulePath>' -ForEach @(
        @{ ModulePath = 'AVM/res/azure-stack-hci/cluster' }
        @{ ModulePath = 'avm/res/Azure-stack-hci/cluster' }
        @{ ModulePath = 'avm\res\azure-stack-hci\cluster' }
        @{ ModulePath = '/avm/res/azure-stack-hci/cluster' }
        @{ ModulePath = 'avm/res/azure-stack-hci/cluster/' }
        @{ ModulePath = 'avm/res/azure-stack-hci/cluster ' }
        @{ ModulePath = "avm/res/azure-stack-hci/cluster`n" }
        @{ ModulePath = 'avm/res/azure-stack-hci/*' }
        @{ ModulePath = 'avm/res/azure-stack-hci' }
        @{ ModulePath = 'avm/res/azure-stack-hci/cluster/../child' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; ModulePath = $ModulePath } {
            param($Root, $ModulePath)
            { Get-AvmBicepTestSubscriptionTag -RepositoryRoot $Root -ModulePath $ModulePath } |
                Should -Throw '*exact canonical*'
        }
    }

    It 'validates the entire map, including unrelated entries: <Case>' -ForEach @(
        @{ Case = 'duplicate'; Json = '{"avm/res/test/one":"General","avm/res/test/one":"Azure Local"}' }
        @{ Case = 'miscased key'; Json = '{"avm/res/Test/one":"General"}' }
        @{ Case = 'invalid unrelated key'; Json = '{"unrelated":"General"}' }
        @{ Case = 'null tag'; Json = '{"avm/res/test/one":null}' }
        @{ Case = 'blank tag'; Json = '{"avm/res/test/one":""}' }
        @{ Case = 'padded tag'; Json = '{"avm/res/test/one":" General"}' }
        @{ Case = 'underscore tag'; Json = '{"avm/res/test/one":"Azure_Local"}' }
        @{ Case = 'non-string tag'; Json = '{"avm/res/test/one":true}' }
        @{ Case = 'array'; Json = '[]' }
        @{ Case = 'scalar'; Json = '"General"' }
        @{ Case = 'null'; Json = 'null' }
    ) {
        [IO.File]::WriteAllText($script:path, $Json)
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; ModulePath = $script:modulePath } {
            param($Root, $ModulePath)
            { Get-AvmBicepTestSubscriptionTag -RepositoryRoot $Root -ModulePath $ModulePath } | Should -Throw
        }
    }

    It 'rejects a missing, miscased, non-file or oversized root map: <Case>' -ForEach @(
        @{ Case = 'missing' }
        @{ Case = 'miscased' }
        @{ Case = 'directory' }
        @{ Case = 'oversized' }
    ) {
        Remove-Item -LiteralPath $script:path
        switch ($Case) {
            'miscased' { [IO.File]::WriteAllText((Join-Path $script:root '.Reserved-test-subscriptions.json'), '{}') }
            'directory' { $null = New-Item -ItemType Directory -Path $script:path }
            'oversized' { [IO.File]::WriteAllText($script:path, '{}' + (' ' * (64KB - 1))) }
        }
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; ModulePath = $script:modulePath } {
            param($Root, $ModulePath)
            { Get-AvmBicepTestSubscriptionTag -RepositoryRoot $Root -ModulePath $ModulePath } | Should -Throw
        }
    }

    It 'does not substitute General or a singleton for a missing reserved pool: <Configured>' -ForEach @(
        @{ Configured = $false }
        @{ Configured = $true }
    ) {
        $json = if ($Configured) { ConvertTo-Json -InputObject @($script:pool[1]) -Compress } else { '' }
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; ModulePath = $script:modulePath; Json = $json } {
            param($Root, $ModulePath, $Json)
            { Select-AvmBicepWorkflowSubscription -RepositoryRoot $Root -ModulePath $ModulePath `
                    -PoolJson $Json -FallbackSubscriptionId '00000000-0000-4000-8000-000000000002' } |
                Should -Throw '*singleton fallback*'
        }
    }

    It 'never uses a reserved-only pool for an unmapped module or changes tag casing' {
        $script:pool[0].tag = 'general'
        InModuleScope Avm.Authoring -Parameters @{ Json = (ConvertTo-Json -InputObject @($script:pool[0]) -Compress) } {
            param($Json)
            { Select-AvmBicepWorkflowSubscription -PoolJson $Json `
                    -FallbackSubscriptionId '00000000-0000-4000-8000-000000000002' } |
                Should -Throw "*no 'General'*"
        }
    }

    It 'validates reserved entries before filtering them out of ordinary selection: <Case>' -ForEach @(
        @{ Case = 'null'; Value = $null }
        @{ Case = 'blank'; Value = '' }
        @{ Case = 'padded'; Value = 'Azure Local ' }
        @{ Case = 'underscore'; Value = 'Azure_Local' }
        @{ Case = 'repeated hyphen'; Value = 'Azure--Local' }
        @{ Case = 'too long'; Value = ('A' * 65) }
        @{ Case = 'number'; Value = 1 }
        @{ Case = 'array'; Value = @('General') }
    ) {
        $script:pool[0].tag = $Value
        InModuleScope Avm.Authoring -Parameters @{ Json = (ConvertTo-Json -InputObject $script:pool -Depth 5 -Compress) } {
            param($Json)
            { Select-AvmBicepWorkflowSubscription -PoolJson $Json } | Should -Throw '*tag must be*'
        }
    }

    It 'rejects duplicate properties, miscased tags and unknown fields: <Property>' -ForEach @(
        @{ Property = '"tag":"Azure Local","tag":"General"' }
        @{ Property = '"tag":"Azure Local","Tag":"General"' }
        @{ Property = '"Tag":"Azure Local"' }
        @{ Property = '"extra":"General"' }
    ) {
        $json = '[{"id":"00000000-0000-4000-8000-000000000001","name":"one",' + $Property + '}]'
        InModuleScope Avm.Authoring -Parameters @{ Json = $json } {
            param($Json)
            { Select-AvmBicepWorkflowSubscription -PoolJson $Json } | Should -Throw '*duplicate, miscased, or unknown*'
        }
    }

    It 'rejects canonical duplicate IDs across different tags before filtering' {
        $script:pool[1].id = $script:pool[0].id.ToLowerInvariant()
        InModuleScope Avm.Authoring -Parameters @{ Json = (ConvertTo-Json -InputObject $script:pool -Compress) } {
            param($Json)
            { Select-AvmBicepWorkflowSubscription -PoolJson $Json } | Should -Throw '*distinct*GUIDs*'
        }
    }
}
