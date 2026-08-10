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

    It 'does not create the directory with -Fix when the rule declares no fix' {
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

    It 'creates the missing directory and declared placeholder with -Fix' {
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.tests-exists'
                Kind        = 'DirectoryMustExist'
                Description = 'tests/ must exist'
                Parameters  = @{ Path = 'tests'; FixCreateFile = '.gitkeep' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustExist -Rule $R -TargetRoot $T -Fix
        }

        $result.Status | Should -Be 'fixed'
        $result.FilesChanged | Should -Be 1
        Join-Path $script:tmp 'tests' | Should -Exist
        $placeholder = Join-Path $script:tmp 'tests' '.gitkeep'
        $placeholder | Should -Exist
        [System.IO.File]::ReadAllBytes($placeholder).Count | Should -Be 0
    }

    It 'fails when the directory does not contain the required number of child directories' {
        $examples = Join-Path $script:tmp 'examples'
        New-Item -ItemType Directory -Path $examples | Out-Null
        Set-Content -LiteralPath (Join-Path $examples '.terraform-docs.yml') -Value '# config'
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.examples-contain-example'
                Kind        = 'DirectoryMustExist'
                Description = 'examples/ must contain an example'
                Parameters  = @{ Path = 'examples'; MinimumChildDirectories = 1 }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustExist -Rule $R -TargetRoot $T
        }

        $result.Status | Should -Be 'fail'
        $result.Issues[0].Message | Should -Match 'at least 1 immediate child directory; found 0'
    }

    It 'passes when at least one immediate child directory exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'examples/default') -Force | Out-Null
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.examples-contain-example'
                Kind        = 'DirectoryMustExist'
                Description = 'examples/ must contain an example'
                Parameters  = @{ Path = 'examples'; MinimumChildDirectories = 1 }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleDirectoryMustExist -Rule $R -TargetRoot $T
        }

        $result.Status | Should -Be 'pass'
        @($result.Issues).Count | Should -Be 0
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
