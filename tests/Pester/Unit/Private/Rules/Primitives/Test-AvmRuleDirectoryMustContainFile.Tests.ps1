#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

Describe 'Test-AvmRuleDirectoryMustContainFile primitive' {
    BeforeEach {
        $script:tmp = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
        $script:rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.unit-fixture'
                Kind        = 'DirectoryMustContainFile'
                Description = 'unit test fixture exists'
                Parameters  = @{
                    Path    = 'tests/unit'
                    Pattern = '*.tftest.hcl'
                }
            }
        }
    }

    It 'passes when a direct matching file exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'tests/unit') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:tmp 'tests/unit/main.tftest.hcl') -Value '# test'

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustContainFile -Rule $R -TargetRoot $T
        }

        $result.Status | Should -Be 'pass'
        @($result.Issues).Count | Should -Be 0
    }

    It 'fails when the directory is missing' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustContainFile -Rule $R -TargetRoot $T
        }

        $result.Status | Should -Be 'fail'
        $result.Issues[0].File | Should -Be 'tests/unit'
        $result.Issues[0].Message | Should -Match ([regex]::Escape('*.tftest.hcl'))
    }

    It 'fails when the directory contains only non-matching files' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'tests/unit') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:tmp 'tests/unit/README.md') -Value '# tests'

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustContainFile -Rule $R -TargetRoot $T
        }

        $result.Status | Should -Be 'fail'
    }

    It 'does not count a nested matching file' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'tests/unit/nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:tmp 'tests/unit/nested/main.tftest.hcl') -Value '# nested'

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustContainFile -Rule $R -TargetRoot $T
        }

        $result.Status | Should -Be 'fail'
    }

    It 'never creates placeholder content with Fix' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustContainFile -Rule $R -TargetRoot $T -Fix
        }

        $result.Status | Should -Be 'fail'
        Test-Path -LiteralPath (Join-Path $script:tmp 'tests/unit') | Should -BeFalse
        $result.FilesChanged | Should -Be 0
    }
}
