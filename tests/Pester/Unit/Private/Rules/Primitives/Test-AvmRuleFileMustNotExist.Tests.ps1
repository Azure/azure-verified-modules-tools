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

    It 'appends source content and removes the source when the rename destination already exists' {
        $src = Join-Path $script:tmp 'output.tf'
        $destination = Join-Path $script:tmp 'outputs.tf'
        $sourceText = 'output "from_source" {}'
        $destinationText = 'output "existing" {}'
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($src, $sourceText, $utf8NoBom)
        [System.IO.File]::WriteAllText($destination, $destinationText, $utf8NoBom)
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
        $result.FilesChanged | Should -Be 2
        Test-Path -LiteralPath $src -PathType Leaf | Should -BeFalse
        [System.IO.File]::ReadAllText($destination) | Should -Be "$destinationText`n$sourceText"
    }

    It 'removes a whitespace-only source without changing an existing destination' {
        $src = Join-Path $script:tmp 'variable.tf'
        $destination = Join-Path $script:tmp 'variables.tf'
        $destinationText = 'variable "existing" {}'
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($src, "`r`n", $utf8NoBom)
        [System.IO.File]::WriteAllText($destination, $destinationText, $utf8NoBom)
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.rename'
                Kind        = 'FileMustNotExist'
                Description = 'no variable.tf'
                Parameters  = @{ Path = 'variable.tf'; FixRenameTo = 'variables.tf' }
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
        [System.IO.File]::ReadAllText($destination) | Should -Be $destinationText
    }

    It 'rejects a rename target that resolves to the source file' {
        $src = Join-Path $script:tmp 'output.tf'
        $sourceText = 'output "existing" {}'
        Set-Content -LiteralPath $src -Value $sourceText -NoNewline
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.rename'
                Kind        = 'FileMustNotExist'
                Description = 'no output.tf'
                Parameters  = @{ Path = 'output.tf'; FixRenameTo = (Join-Path '.' 'output.tf') }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustNotExist -Rule $R -TargetRoot $T -Fix
        }
        $result.Status | Should -Be 'fail'
        @($result.Issues).Count | Should -Be 1
        $result.Issues[0].Message | Should -Match 'same file'
        $result.FilesChanged | Should -Be 0
        Get-Content -LiteralPath $src -Raw | Should -Be $sourceText
    }

    It 'reports a collision when the rename destination is not a file' {
        Set-Content -LiteralPath (Join-Path $script:tmp 'output.tf') -Value '# source' -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'outputs.tf') | Out-Null
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
        Test-Path -LiteralPath (Join-Path $script:tmp 'output.tf') -PathType Leaf | Should -BeTrue
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
