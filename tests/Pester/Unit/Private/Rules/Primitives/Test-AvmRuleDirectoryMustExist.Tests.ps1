#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

Describe 'Test-AvmRuleDirectoryMustExist primitive' {
    BeforeEach {
        $script:tmp = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }

    It 'returns pass when the directory exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'examples') | Out-Null
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.examples-exists'
                Kind        = 'DirectoryMustExist'
                Description = 'examples/ must exist'
                Parameters  = @{ Path = 'examples' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustExist -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'pass'
        @($result.Issues).Count | Should -Be 0
        $result.FilesChanged | Should -Be 0
    }

    It 'returns fail when the directory is missing' {
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.examples-exists'
                Kind        = 'DirectoryMustExist'
                Description = 'examples/ must exist'
                Parameters  = @{ Path = 'examples' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustExist -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'fail'
        @($result.Issues).Count | Should -Be 1
        $result.Issues[0].File | Should -Be 'examples'
        $result.Issues[0].Message | Should -Match "Required directory 'examples'"
    }

    It 'returns fail when a file (not directory) sits at the target path' {
        Set-Content -LiteralPath (Join-Path $script:tmp 'examples') -Value '# not-a-dir' -NoNewline
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.examples-exists'
                Kind        = 'DirectoryMustExist'
                Description = 'examples/ must exist'
                Parameters  = @{ Path = 'examples' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustExist -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'fail'
    }

    It 'never creates the directory even when -Fix is set (no silent .gitkeep materialisation)' {
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.examples-exists'
                Kind        = 'DirectoryMustExist'
                Description = 'examples/ must exist'
                Parameters  = @{ Path = 'examples' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustExist -Rule $R -TargetRoot $T -Fix
        }
        $result.Status | Should -Be 'fail'
        Test-Path -LiteralPath (Join-Path $script:tmp 'examples') | Should -BeFalse
    }

    It 'propagates the rule Severity into the emitted Issue' {
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.tests-exists'
                Kind        = 'DirectoryMustExist'
                Description = 'tests/ should exist'
                Severity    = 'warning'
                Parameters  = @{ Path = 'tests' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustExist -Rule $R -TargetRoot $T
        }
        $result.Issues[0].Severity | Should -Be 'warning'
    }
}
