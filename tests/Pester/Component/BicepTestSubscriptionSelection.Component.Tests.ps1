#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')

    function New-SelectionCase {
        param([string] $Root, [string] $Directory = 'defaults')
        $casePath = Join-Path $Root 'tests' 'e2e' $Directory
        $null = New-Item -ItemType Directory -Path $casePath -Force
        [IO.File]::WriteAllText((Join-Path $Root 'main.bicep'), 'param name string')
        [IO.File]::WriteAllText((Join-Path $casePath 'main.test.bicep'), 'param name string')
    }
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: native Bicep test subscription selection' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:root
        $script:mapPath = Join-Path $script:root '.reserved-test-subscriptions.json'
        [IO.File]::WriteAllText($script:mapPath, '{}')
        $script:modulePath = 'avm/res/example/module'
        $script:moduleRoot = Join-Path $script:root 'avm' 'res' 'example' 'module'
        $script:pool = @(
            @{ id = '11111111-1111-4111-8111-111111111111'; name = 'reserved'; tag = 'Azure Local' }
            @{ id = 'ABCDEF01-ABCD-4ABC-8ABC-ABCDEF012345'; name = 'first' }
            @{ id = '22222222-2222-4222-8222-222222222222'; name = 'second'; tag = 'General' }
        )
        $script:options = @{
            Path = $script:root
            ModulePath = $script:modulePath
            TestSubscriptionIds = ConvertTo-Json -InputObject $script:pool -Compress
            RandomSeed = 42
            SkipModuleVersionCheck = $true
        }
        Mock -ModuleName Avm.Authoring Test-AvmModuleVersion {}
        Mock -ModuleName Avm.Authoring Invoke-AvmProcess { throw 'Selection must not run a subprocess.' }
        Mock -ModuleName Avm.Authoring Invoke-AvmHttp { throw 'Selection must not contact a remote service.' }
        Mock -ModuleName Avm.Authoring Resolve-AvmTool { throw 'Selection must not resolve a compiler or dependencies.' }
    }
    AfterEach {
        Should -Invoke -ModuleName Avm.Authoring Invoke-AvmProcess -Times 0 -Exactly
        Should -Invoke -ModuleName Avm.Authoring Invoke-AvmHttp -Times 0 -Exactly
        Should -Invoke -ModuleName Avm.Authoring Resolve-AvmTool -Times 0 -Exactly
    }

    It 'exports the real selector with an integer package capability' {
        (Get-Command Select-AvmTestSubscription).ModuleName | Should -BeExactly 'Avm.Authoring'
        $capability = (Get-Module Avm.Authoring).PrivateData.AvmCapabilities.BicepTestSubscriptionSelection
        $capability | Should -BeOfType ([int])
        $capability | Should -Be 1
    }

    It 'selects only General entries and preserves the original index, spelling and canonical digest' {
        $selected = @(0..3 | ForEach-Object { Select-AvmTestSubscription @script:options -CaseIndex $_ })
        @($selected.Tag | Select-Object -Unique) | Should -Be @('General')
        @($selected.Index | Sort-Object -Unique) | Should -Be @(1, 2)
        @($selected.ModulePath | Select-Object -Unique) | Should -Be @($script:modulePath)
        $first = @($selected | Where-Object Index -EQ 1)[0]
        $first.SubscriptionId | Should -BeExactly $script:pool[1].id
        $first.Name | Should -BeExactly 'first'
        $bytes = [Text.Encoding]::UTF8.GetBytes('abcdef01-abcd-4abc-8abc-abcdef012345')
        $first.Key | Should -BeExactly ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant())
        @($first.PSObject.Properties.Name | Sort-Object) |
            Should -Be @('Index', 'Key', 'ModulePath', 'Name', 'SubscriptionId', 'Tag')
        Should -Invoke -ModuleName Avm.Authoring Test-AvmModuleVersion -Times 4 -Exactly -ParameterFilter { $SkipModuleVersionCheck }
    }

    It 'repeats the same binding and preserves order-independent seeded assignment when the JSON is reordered' {
        $first = Select-AvmTestSubscription @script:options -CaseIndex 7
        $repeat = Select-AvmTestSubscription @script:options -CaseIndex 7
        $repeat.Index | Should -Be $first.Index
        $repeat.Key | Should -BeExactly $first.Key
        $script:options.TestSubscriptionIds = ConvertTo-Json -InputObject @(
            $script:pool[2], $script:pool[0], $script:pool[1]) -Compress
        $reordered = Select-AvmTestSubscription @script:options -CaseIndex 7
        $reordered.SubscriptionId | Should -BeExactly $first.SubscriptionId
        $reordered.Key | Should -BeExactly $first.Key
        $reordered.Index | Should -Not -Be $first.Index
    }

    It 'returns a reserved selection without treating it as permission to execute' {
        [IO.File]::WriteAllText($script:mapPath, '{"avm/res/example/module":"Azure Local"}')
        $selected = Select-AvmTestSubscription @script:options
        $selected.ModulePath | Should -BeExactly $script:modulePath
        $selected.Tag | Should -BeExactly 'Azure Local'
        $selected.Index | Should -Be 0
    }

    It 'resolves a reserved child owner from an exact example <Example>' -ForEach @(
        @{ Example = 'child/tests/e2e/defaults' }
        @{ Example = 'child/tests/e2e/defaults/main.test.bicep' }
    ) {
        New-SelectionCase -Root $script:moduleRoot
        New-SelectionCase -Root (Join-Path $script:moduleRoot 'child')
        [IO.File]::WriteAllText($script:mapPath, '{"avm/res/example/module/child":"Azure Local"}')
        $selected = Select-AvmTestSubscription @script:options -Example $Example
        $selected.ModulePath | Should -BeExactly 'avm/res/example/module/child'
        $selected.Tag | Should -BeExactly 'Azure Local'
        $selected.Index | Should -Be 0
        (Select-AvmTestSubscription @script:options -Example 'tests/e2e/defaults').Tag | Should -BeExactly 'General'
    }

    It 'does not inherit a parent reservation for an unmapped child or a child reservation for its parent' {
        New-SelectionCase -Root $script:moduleRoot
        New-SelectionCase -Root (Join-Path $script:moduleRoot 'child')
        [IO.File]::WriteAllText($script:mapPath, '{"avm/res/example/module":"Azure Local"}')
        (Select-AvmTestSubscription @script:options -Example 'child/tests/e2e/defaults').Tag | Should -BeExactly 'General'
        [IO.File]::WriteAllText($script:mapPath, '{"avm/res/example/module/child":"Azure Local"}')
        (Select-AvmTestSubscription @script:options).Tag | Should -BeExactly 'General'
    }

    It 'discovers the exact owner under a source-less family root' {
        New-SelectionCase -Root (Join-Path $script:moduleRoot 'sub-scope')
        [IO.File]::WriteAllText($script:mapPath, '{"avm/res/example/module/sub-scope":"Azure Local"}')
        Test-Path -LiteralPath (Join-Path $script:moduleRoot 'main.bicep') | Should -BeFalse
        $selected = Select-AvmTestSubscription @script:options -Example 'sub-scope/tests/e2e/defaults'
        $selected.ModulePath | Should -BeExactly 'avm/res/example/module/sub-scope'
        $selected.Tag | Should -BeExactly 'Azure Local'
    }

    It 'uses discovery ownership rather than interpreting nested example directory names as module paths' {
        New-SelectionCase -Root $script:moduleRoot -Directory 'nested/defaults'
        $selected = Select-AvmTestSubscription @script:options -Example 'tests/e2e/nested/defaults'
        $selected.ModulePath | Should -BeExactly $script:modulePath
        $selected.Tag | Should -BeExactly 'General'
    }

    It 'rejects a nonexact or unknown example: <Example>' -ForEach @(
        @{ Example = 'defaults' }
        @{ Example = './tests/e2e/defaults' }
        @{ Example = 'tests/e2e/defaults/' }
        @{ Example = 'tests/e2e/Defaults' }
        @{ Example = 'tests\e2e\defaults' }
        @{ Example = 'tests/e2e/*' }
        @{ Example = '../module/tests/e2e/defaults' }
        @{ Example = 'tests/e2e/missing' }
        @{ Example = ' ' }
    ) {
        New-SelectionCase -Root $script:moduleRoot
        { Select-AvmTestSubscription @script:options -Example $Example } | Should -Throw '*exactly one runnable native test*'
    }

    It 'rejects opted-out examples instead of selecting their parent reservation' {
        New-SelectionCase -Root (Join-Path $script:moduleRoot 'child')
        [IO.File]::WriteAllText((Join-Path $script:moduleRoot 'child' 'tests' 'e2e' 'defaults' '.e2eignore'), '')
        { Select-AvmTestSubscription @script:options -Example 'child/tests/e2e/defaults' } |
            Should -Throw '*exactly one runnable native test*'
    }

    It 'validates ModulePath before native filesystem discovery: <ModulePath>' -ForEach @(
        @{ ModulePath = 'avm/res/example/../outside' }
        @{ ModulePath = 'AVM/res/example/module' }
        @{ ModulePath = 'avm/res/example/module ' }
    ) {
        $script:options.ModulePath = $ModulePath
        Mock -ModuleName Avm.Authoring Get-AvmBicepTestCase { throw 'Invalid paths must not reach discovery.' }
        { Select-AvmTestSubscription @script:options -Example 'tests/e2e/defaults' } | Should -Throw '*exact canonical*'
        Should -Invoke -ModuleName Avm.Authoring Get-AvmBicepTestCase -Times 0 -Exactly
    }

    It 'validates unrelated reservation entries and rejects duplicate properties' {
        [IO.File]::WriteAllText($script:mapPath, '{"avm/res/example/other":"General","avm/res/example/other":"Azure Local"}')
        { Select-AvmTestSubscription @script:options } | Should -Throw '*unique canonical*'
    }

    It 'never searches a parent repository for a missing reservation map' {
        New-SelectionCase -Root $script:moduleRoot
        $script:options.Path = $script:moduleRoot
        { Select-AvmTestSubscription @script:options } | Should -Throw '*root .reserved-test-subscriptions.json*'
    }

    It 'requires a directory rather than a reservation file as Path' {
        $script:options.Path = $script:mapPath
        { Select-AvmTestSubscription @script:options } | Should -Throw '*filesystem repository directory*'
    }

    It 'validates the entire explicit pool before tag filtering: <Label>' -ForEach @(
        @{ Label = 'whitespace'; Json = ' ' }
        @{ Label = 'empty array'; Json = '[]' }
        @{ Label = 'zero GUID'; Json = '[{"id":"00000000-0000-0000-0000-000000000000","name":"invalid"}]' }
        @{ Label = 'unknown property'; Json = '[{"id":"11111111-1111-4111-8111-111111111111","name":"reserved","tag":"Azure Local","extra":true}]' }
        @{ Label = 'duplicate property'; Json = '[{"id":"11111111-1111-4111-8111-111111111111","name":"reserved","tag":"Azure Local","tag":"General"}]' }
        @{ Label = 'duplicate across tags'; Json = '[{"id":"11111111-1111-4111-8111-111111111111","name":"reserved","tag":"Azure Local"},{"id":"11111111-1111-4111-8111-111111111111","name":"ordinary"}]' }
    ) {
        $script:options.TestSubscriptionIds = $Json
        { Select-AvmTestSubscription @script:options } | Should -Throw
    }

    It 'does not use a reserved-only pool for General or a General-only pool for a reserved owner' {
        $script:options.TestSubscriptionIds = ConvertTo-Json -InputObject @($script:pool[0]) -Compress
        { Select-AvmTestSubscription @script:options } | Should -Throw "*no 'General'*"
        [IO.File]::WriteAllText($script:mapPath, '{"avm/res/example/module":"Azure Local"}')
        $script:options.TestSubscriptionIds = ConvertTo-Json -InputObject @($script:pool[1]) -Compress
        { Select-AvmTestSubscription @script:options } | Should -Throw "*no 'Azure Local'*"
    }
}
