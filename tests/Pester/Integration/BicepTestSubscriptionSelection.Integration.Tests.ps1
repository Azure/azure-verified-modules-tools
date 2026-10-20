#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: packaged Bicep subscription selection' -Tag Integration {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $source = Join-Path $repoRoot 'out' 'Avm.Authoring'
        $script:package = Join-Path $TestDrive 'installed' 'Avm.Authoring'
        $null = New-Item -ItemType Directory -Path (Split-Path $script:package) -Force
        Copy-Item -LiteralPath $source -Destination $script:package -Recurse
        Import-Module (Join-Path $script:package 'Avm.Authoring.psd1') -Force
    }
    AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

    BeforeEach {
        $script:consumer = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $moduleRoot = Join-Path $script:consumer 'avm' 'res' 'example' 'module'
        $casePath = Join-Path $moduleRoot 'child' 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $casePath -Force
        [IO.File]::WriteAllText((Join-Path $moduleRoot 'child' 'main.bicep'), 'param name string')
        [IO.File]::WriteAllText((Join-Path $casePath 'main.test.bicep'), 'param name string')
        [IO.File]::WriteAllText((Join-Path $script:consumer '.reserved-test-subscriptions.json'),
            '{"avm/res/example/module/child":"Azure Local"}')
        $script:options = @{
            Path = $script:consumer
            ModulePath = 'avm/res/example/module'
            TestSubscriptionIds = '[{"id":"11111111-1111-4111-8111-111111111111","name":"reserved","tag":"Azure Local"},{"id":"22222222-2222-4222-8222-222222222222","name":"ordinary"}]'
            RandomSeed = 42
            CaseIndex = 5
            SkipModuleVersionCheck = $true
        }
    }

    It 'executes the exported selector from an independent installed package without registry utilities' {
        (Get-Command Select-AvmTestSubscription).Module.ModuleBase | Should -BeExactly $script:package
        Test-Path -LiteralPath (Join-Path $script:consumer 'utilities') | Should -BeFalse
        $capability = (Get-Module Avm.Authoring).PrivateData.AvmCapabilities.BicepTestSubscriptionSelection
        $capability | Should -BeOfType ([int])
        $capability | Should -Be 1
        $selected = Select-AvmTestSubscription @script:options
        $selected.Tag | Should -BeExactly 'General'
        $selected.Index | Should -Be 1
        $repeat = Select-AvmTestSubscription @script:options
        $repeat.Index | Should -Be $selected.Index
        $repeat.Key | Should -BeExactly $selected.Key
    }

    It 'resolves the reserved child through packaged discovery instead of a caller-side owner parser' {
        $selected = Select-AvmTestSubscription @script:options -Example 'child/tests/e2e/defaults'
        $selected.ModulePath | Should -BeExactly 'avm/res/example/module/child'
        $selected.Tag | Should -BeExactly 'Azure Local'
        $selected.Index | Should -Be 0
        $script:options.TestSubscriptionIds = '[{"id":"22222222-2222-4222-8222-222222222222","name":"ordinary"}]'
        { Select-AvmTestSubscription @script:options -Example 'child/tests/e2e/defaults' } |
            Should -Throw "*no 'Azure Local'*"
    }

    It 'rejects missing root policy and malformed pools without a source-checkout fallback' {
        $policyPath = Join-Path $script:consumer '.reserved-test-subscriptions.json'
        if ($IsWindows) {
            [IO.File]::SetAttributes($policyPath, [IO.File]::GetAttributes($policyPath) -bor [IO.FileAttributes]::Hidden)
        }
        ([IO.File]::GetAttributes($policyPath) -band [IO.FileAttributes]::Hidden) |
            Should -Be ([IO.FileAttributes]::Hidden)
        $script:options.TestSubscriptionIds = 'invalid'
        { Select-AvmTestSubscription @script:options } | Should -Throw '*strict JSON*'
        Remove-Item -LiteralPath $policyPath -Force
        Test-Path -LiteralPath $policyPath | Should -BeFalse
        { Select-AvmTestSubscription @script:options } | Should -Throw '*root .reserved-test-subscriptions.json*'
    }
}
