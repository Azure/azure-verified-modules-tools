BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:action = Join-Path $script:root 'repository-management' 'test-tenant' 'actions' 'resolve-test-tenant' 'Resolve-TestTenant.ps1'
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
}

Describe 'Test tenant action output' -Tag Component {
    It 'appends complete single-line outputs with LF and no BOM' {
        $output = Join-Path $TestDrive 'action-output'
        & $script:action -ModulePath 'avm/res/network/front-door/.test/common' `
            -ModuleConfigJson '{"default":"legacy","modules":{"avm/res/network/front-door":"bami"}}' `
            -BamiSettingsJson ((New-AvmTestBamiSettings) | ConvertTo-Json -Depth 5) -OutputPath $output
        $lines = Get-Content -LiteralPath $output
        $lines.Count | Should -Be 2
        $lines[0] | Should -BeExactly 'test-tenant=bami'
        $settings = $lines[1].Substring('settings-json='.Length) | ConvertFrom-Json -AsHashtable
        $settings.Count | Should -Be 5
        $settings.Contains('TEST_BAMI_CONTROLLER_CLIENT_ID') | Should -BeFalse
        $bytes = [System.IO.File]::ReadAllBytes($output)
        $bytes | Should -Not -Contain 13
        $bytes[0] | Should -Be 116
    }

    It 'writes nothing for invalid explicit BAMI or WhatIf' {
        $output = Join-Path $TestDrive 'no-output'
        {
            & $script:action -ModulePath 'avm/res/network/front-door' `
                -ModuleConfigJson '{"default":"legacy","modules":{"avm/res/network/front-door":"bami"}}' -OutputPath $output
        } | Should -Throw
        Test-Path -LiteralPath $output | Should -BeFalse
        & $script:action -ModulePath 'avm/res/network/front-door' -OutputPath $output -WhatIf
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'never emits activation outputs for a test pool containing Persistent' {
        $output = Join-Path $TestDrive 'persistent-overlap-output'
        $bundle = New-AvmTestBamiSettings
        $bundle.TEST_BAMI_SUBSCRIPTION_IDS[0].id = $bundle.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
        {
            & $script:action -ModulePath 'avm/res/network/front-door' `
                -ModuleConfigJson '{"default":"legacy","modules":{"avm/res/network/front-door":"bami"}}' `
                -BamiSettingsJson ($bundle | ConvertTo-Json -Depth 5) -OutputPath $output
        } | Should -Throw '*Persistent*test pool*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }
}
