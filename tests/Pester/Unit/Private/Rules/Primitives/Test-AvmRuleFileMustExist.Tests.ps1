#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

Describe 'Test-AvmRuleFileMustExist primitive' {
    BeforeEach {
        $script:tmp = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }

    It 'returns pass when the required file exists' {
        Set-Content -LiteralPath (Join-Path $script:tmp 'terraform.tf') -Value '# stub' -NoNewline
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.terraform-tf-exists'
                Kind        = 'FileMustExist'
                Description = 'terraform.tf must exist'
                Parameters  = @{ Path = 'terraform.tf' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustExist -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'pass'
        @($result.Issues).Count | Should -Be 0
        $result.FilesChanged | Should -Be 0
    }

    It 'returns fail with one issue when the file is missing' {
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.terraform-tf-exists'
                Kind        = 'FileMustExist'
                Description = 'terraform.tf must exist'
                Parameters  = @{ Path = 'terraform.tf' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustExist -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'fail'
        @($result.Issues).Count | Should -Be 1
        $result.Issues[0].Code | Should -Be 'avm.test.terraform-tf-exists'
        $result.Issues[0].File | Should -Be 'terraform.tf'
        $result.Issues[0].Message | Should -Match "Required file 'terraform.tf'"
    }

    It 'never creates the file even when -Fix is set (no silent stub materialisation)' {
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.terraform-tf-exists'
                Kind        = 'FileMustExist'
                Description = 'terraform.tf must exist'
                Parameters  = @{ Path = 'terraform.tf' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustExist -Rule $R -TargetRoot $T -Fix
        }
        $result.Status | Should -Be 'fail'
        Test-Path -LiteralPath (Join-Path $script:tmp 'terraform.tf') | Should -BeFalse
    }

    It 'propagates the rule Severity into the emitted Issue' {
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.header-md'
                Kind        = 'FileMustExist'
                Description = '_header.md must exist'
                Severity    = 'warning'
                Parameters  = @{ Path = '_header.md' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustExist -Rule $R -TargetRoot $T
        }
        $result.Issues[0].Severity | Should -Be 'warning'
    }

    It 'returns fail when the path exists but is a directory, not a file' {
        $sub = Join-Path $script:tmp 'terraform.tf'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        $rule = InModuleScope 'Avm.Authoring' {
            New-AvmRule -Definition @{
                Id          = 'avm.test.terraform-tf-exists'
                Kind        = 'FileMustExist'
                Description = 'terraform.tf must exist'
                Parameters  = @{ Path = 'terraform.tf' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleFileMustExist -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'fail'
    }
}
