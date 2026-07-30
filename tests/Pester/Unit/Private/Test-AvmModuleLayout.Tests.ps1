#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Test-AvmModuleLayout' {
    It 'returns the manifest for the real module folder' {
        $manifest = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:moduleRoot } {
            param($R)
            Test-AvmModuleLayout -ModuleRoot $R
        }
        $manifest | Should -Not -BeNullOrEmpty
        $manifest.Name | Should -Be 'Avm.Authoring'
        $manifest.PowerShellVersion | Should -BeGreaterOrEqual ([version]'7.4')
    }

    It 'throws AvmConfigurationException when the folder does not exist' {
        $bad = Join-Path $TestDrive 'no-such-module-folder'
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ R = $bad } {
                param($R)
                Test-AvmModuleLayout -ModuleRoot $R
            }
        }
        catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
    }

    It 'throws AvmConfigurationException when the folder casing is wrong' {
        # Stage a copy of just the .psd1 / .psm1 into a mis-cased folder. We
        # do not need a working module here, just enough for the casing check
        # to fire before Test-ModuleManifest validates anything.
        $bad = Join-Path $TestDrive 'avm.authoring'  # lowercase
        New-Item -ItemType Directory -Path $bad -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Destination $bad
        Copy-Item -LiteralPath (Join-Path $script:moduleRoot 'Avm.Authoring.psm1') -Destination $bad

        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ R = $bad } {
                param($R)
                # On Windows the OS file-system is case-insensitive so the
                # casing test fires deterministically on the Split-Path leaf
                # rather than on Get-ChildItem.
                Test-AvmModuleLayout -ModuleRoot $R
            }
        }
        catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message | Should -Match "expected 'Avm.Authoring'"
    }
}

Describe 'Module Resources packaging' {
    It 'ships the three vendored AVM tflint rulesets under Resources/tflint' {
        $tflintDir = Join-Path $script:moduleRoot (Join-Path 'Resources' 'tflint')
        $tflintDir | Should -Exist
        foreach ($file in @('avm.tflint.hcl', 'avm.tflint_module.hcl', 'avm.tflint_example.hcl')) {
            $path = Join-Path $tflintDir $file
            $path | Should -Exist
            (Get-Item -LiteralPath $path).Length | Should -BeGreaterThan 0
        }
    }

    It 'pins the AVM tflint ruleset plugin in the vendored configs' {
        $tflintDir = Join-Path $script:moduleRoot (Join-Path 'Resources' 'tflint')
        foreach ($file in @('avm.tflint.hcl', 'avm.tflint_module.hcl', 'avm.tflint_example.hcl')) {
            $content = Get-Content -LiteralPath (Join-Path $tflintDir $file) -Raw
            $content | Should -Match 'plugin\s+"avm"'
        }
    }

    It 'ships the mapotf pre-commit config bundle under Resources/mapotf/pre-commit' {
        $mapotfDir = Join-Path $script:moduleRoot (Join-Path 'Resources' (Join-Path 'mapotf' 'pre-commit'))
        $mapotfDir | Should -Exist
        $expected = @(
            'avm_headers_for_azapi.mptf.hcl'
            'main_telemetry_tf.mptf.hcl'
            'move_misplaced_blocks.mptf.hcl'
            'order_module_attrs.mptf.hcl'
            'order_resource_attrs.mptf.hcl'
            'order_resource_meta.mptf.hcl'
            'required_provider_versions.mptf.hcl'
            'sort_outputs.mptf.hcl'
            'sort_variables.mptf.hcl'
        )
        foreach ($file in $expected) {
            $path = Join-Path $mapotfDir $file
            $path | Should -Exist
            (Get-Item -LiteralPath $path).Length | Should -BeGreaterThan 0
        }
        @(Get-ChildItem -LiteralPath $mapotfDir -Filter '*.mptf.hcl' -File).Count | Should -Be $expected.Count
    }

    It 'ships the consolidated pin manifest and no legacy tools lock' {
        $resources = Join-Path $script:moduleRoot 'Resources'
        (Join-Path $resources 'avm.pins.jsonc') | Should -Exist
        (Join-Path $resources 'tools.lock.psd1') | Should -Not -Exist
    }
}
