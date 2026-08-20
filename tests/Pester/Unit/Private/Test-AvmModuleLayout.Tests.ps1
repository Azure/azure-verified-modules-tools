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

    It 'ships attestation-only AVM plugin declarations in the vendored configs' {
        $tflintDir = Join-Path $script:moduleRoot (Join-Path 'Resources' 'tflint')
        foreach ($file in @('avm.tflint.hcl', 'avm.tflint_module.hcl', 'avm.tflint_example.hcl')) {
            $content = Get-Content -LiteralPath (Join-Path $tflintDir $file) -Raw
            $content | Should -Match 'plugin\s+"avm"'
            $content | Should -Match 'signature\s*=\s*"attestation"'
            $content | Should -Not -Match 'signing_key\s*='
            $content | Should -Match 'disabled_by_default\s*=\s*true'
        }
    }

    It 'relies on default-enabled AVM rules and preserves only scope exemptions' {
        $tflintDir = Join-Path $script:moduleRoot (Join-Path 'Resources' 'tflint')
        $root = Get-Content -LiteralPath (Join-Path $tflintDir 'avm.tflint.hcl') -Raw
        $module = Get-Content -LiteralPath (Join-Path $tflintDir 'avm.tflint_module.hcl') -Raw
        $example = Get-Content -LiteralPath (Join-Path $tflintDir 'avm.tflint_example.hcl') -Raw

        foreach ($content in @($root, $module, $example)) {
            foreach ($removedRule in @(
                    'azurerm_arg_order',
                    'azurerm_resource_tag',
                    'terraform_count_index_usage',
                    'terraform_locals_order',
                    'terraform_output_separate',
                    'terraform_required_providers_declaration',
                    'terraform_required_version_declaration',
                    'terraform_resource_data_arg_layout',
                    'terraform_variable_nullable_false',
                    'terraform_variable_separate',
                    'terraform_versions_file',
                    'tfnfr26'
                )) {
                $content | Should -Not -Match ('rule\s+"{0}"' -f $removedRule)
            }
        }

        foreach ($defaultEnabledRule in @(
                'terraform_heredoc_usage',
                'terraform_module_provider_declaration',
                'terraform_sensitive_variable_no_default',
                'azapi_resource_tag',
                'terraform_tf_file',
                'required_module_source_tffr1',
                'required_output_rmfr7'
            )) {
            $root | Should -Not -Match ('rule\s+"{0}"' -f $defaultEnabledRule)
            $module | Should -Not -Match ('rule\s+"{0}"' -f $defaultEnabledRule)
        }

        $module | Should -Match '(?s)rule\s+"provider_modtm_version_constraint"\s*\{\s*enabled\s*=\s*false\s*\}'
        foreach ($exampleRule in @(
                'terraform_heredoc_usage',
                'terraform_module_provider_declaration',
                'terraform_sensitive_variable_no_default',
                'azapi_resource_tag',
                'terraform_tf_file',
                'required_module_source_tffr1',
                'required_output_rmfr7',
                'provider_modtm_version_constraint'
            )) {
            $example | Should -Match (
                '(?s)rule\s+"{0}"\s*\{{\s*enabled\s*=\s*false\s*\}}' -f $exampleRule)
        }
        $example | Should -Match '(?s)rule\s+"terraform_required_providers"\s*\{\s*enabled\s*=\s*true\s*\}'
        $example | Should -Match '(?s)rule\s+"terraform_required_version"\s*\{\s*enabled\s*=\s*true\s*\}'
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
            'order_terraform.mptf.hcl'
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

    It 'ships a deterministic Terraform declaration ordering transform' {
        $path = Join-Path `
            $script:moduleRoot `
            (Join-Path 'Resources' (Join-Path 'mapotf' (Join-Path 'pre-commit' 'order_terraform.mptf.hcl')))
        $content = Get-Content -LiteralPath $path -Raw

        $content | Should -Match 'head_attributes\s*=\s*\["required_version"\]'
        $content | Should -Match 'body_attributes\s*=\s*\["experiments", "backend", "cloud", "provider_meta"\]'
        $content | Should -Match 'foot_attributes\s*=\s*\["required_providers"\]'
    }

    It 'ships the consolidated pin manifest and no legacy tools lock' {
        $resources = Join-Path $script:moduleRoot 'Resources'
        (Join-Path $resources 'avm.pins.jsonc') | Should -Exist
        (Join-Path $resources 'tools.lock.psd1') | Should -Not -Exist
    }
}
