#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

Describe 'Test-AvmRuleFileMustNotExist primitive' {
    BeforeEach {
        $script:tmp = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }

    It 'returns pass with zero issues when the file is absent' {
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.rename'
                Kind        = 'FileMustNotExist'
                Description = 'no output.tf'
                Parameters  = @{ Path = 'output.tf'; FixRenameTo = 'outputs.tf' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustNotExist -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'pass'
        @($result.Issues).Count | Should -Be 0
        $result.FilesChanged | Should -Be 0
    }

    It 'returns fail with one issue when the file exists and -Fix is not set' {
        Set-Content -LiteralPath (Join-Path $script:tmp 'output.tf') -Value '# stub' -NoNewline
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.rename'
                Kind        = 'FileMustNotExist'
                Description = 'no output.tf'
                Parameters  = @{ Path = 'output.tf'; FixRenameTo = 'outputs.tf' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustNotExist -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'fail'
        @($result.Issues).Count | Should -Be 1
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].Code | Should -Be 'avm.test.rename'
        $result.Issues[0].File | Should -Be 'output.tf'
        $result.Issues[0].Message | Should -Match "rename to 'outputs.tf'"
    }

    It 'renames the file when -Fix is set and FixRenameTo is declared' {
        $src = Join-Path $script:tmp 'output.tf'
        Set-Content -LiteralPath $src -Value '# stub' -NoNewline
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.rename'
                Kind        = 'FileMustNotExist'
                Description = 'no output.tf'
                Parameters  = @{ Path = 'output.tf'; FixRenameTo = 'outputs.tf' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustNotExist -Rule $R -TargetRoot $T -Fix
        }
        $result.Status | Should -Be 'fixed'
        @($result.Issues).Count | Should -Be 0
        $result.FilesChanged | Should -Be 1
        Test-Path -LiteralPath $src -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:tmp 'outputs.tf') -PathType Leaf | Should -BeTrue
    }

    It 'still reports a violation when -Fix is set but no FixRenameTo is declared (no silent delete)' {
        Set-Content -LiteralPath (Join-Path $script:tmp 'Makefile') -Value '# stub' -NoNewline
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.makefile'
                Kind        = 'FileMustNotExist'
                Description = 'no Makefile'
                Parameters  = @{ Path = 'Makefile' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustNotExist -Rule $R -TargetRoot $T -Fix
        }
        $result.Status | Should -Be 'fail'
        @($result.Issues).Count | Should -Be 1
        $result.FilesChanged | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:tmp 'Makefile') -PathType Leaf | Should -BeTrue
    }

    It 'reports a collision when -Fix is set, FixRenameTo declared, and destination already exists' {
        Set-Content -LiteralPath (Join-Path $script:tmp 'output.tf')  -Value '# a' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:tmp 'outputs.tf') -Value '# b' -NoNewline
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.rename'
                Kind        = 'FileMustNotExist'
                Description = 'no output.tf'
                Parameters  = @{ Path = 'output.tf'; FixRenameTo = 'outputs.tf' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustNotExist -Rule $R -TargetRoot $T -Fix
        }
        $result.Status | Should -Be 'fail'
        @($result.Issues).Count | Should -Be 1
        $result.Issues[0].Message | Should -Match 'destination already exists'
        $result.FilesChanged | Should -Be 0
        # both files still present
        Test-Path -LiteralPath (Join-Path $script:tmp 'output.tf') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:tmp 'outputs.tf') -PathType Leaf | Should -BeTrue
    }

    It 'propagates the rule Severity into the emitted Issue' {
        Set-Content -LiteralPath (Join-Path $script:tmp 'Makefile') -Value '# stub' -NoNewline
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.makefile'
                Kind        = 'FileMustNotExist'
                Description = 'no Makefile'
                Severity    = 'warning'
                Parameters  = @{ Path = 'Makefile' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustNotExist -Rule $R -TargetRoot $T
        }
        $result.Issues[0].Severity | Should -Be 'warning'
    }
}
