#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

Describe 'Test-AvmRuleTerraformScopesMustBeDirectChildren primitive' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.terraform-scopes-direct'
                Kind        = 'TerraformScopesMustBeDirectChildren'
                Description = 'Terraform scopes must be direct children'
                Parameters  = @{ ScopeDirectories = @('modules', 'examples') }
            }
        }
    }

    It 'passes for direct module and example Terraform roots' {
        foreach ($path in @('modules/network/main.tf', 'examples/default/main.tf')) {
            $file = Join-Path $script:root $path
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            Set-Content -LiteralPath $file -Value '# terraform' -Encoding utf8
        }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:rule; T = $script:root } {
            param($R, $T)
            Test-AvmRuleTerraformScopesMustBeDirectChildren -Rule $R -TargetRoot $T
        }

        $result.Status | Should -Be 'pass'
        @($result.Issues).Count | Should -Be 0
    }

    It 'rejects nested Terraform roots while ignoring nested non-Terraform assets' {
        foreach ($path in @(
                'modules/network/private/main.tf',
                'examples/default/secondary/main.tf',
                'modules/network/scripts/generate.ps1',
                'examples/default/assets/template.json'
            )) {
            $file = Join-Path $script:root $path
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            Set-Content -LiteralPath $file -Value '# fixture' -Encoding utf8
        }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:rule; T = $script:root } {
            param($R, $T)
            Test-AvmRuleTerraformScopesMustBeDirectChildren -Rule $R -TargetRoot $T
        }

        $result.Status | Should -Be 'fail'
        @($result.Issues).Count | Should -Be 2
        @($result.Issues.File | Sort-Object) | Should -Be @(
            'examples/default/secondary/main.tf'
            'modules/network/private/main.tf'
        )
        @($result.Issues.Code | Select-Object -Unique) | Should -Be @('avm.test.terraform-scopes-direct')
        $result.FilesChanged | Should -Be 0
    }
}
