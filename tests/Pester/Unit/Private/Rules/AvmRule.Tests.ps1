#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

Describe 'Test-AvmRule + New-AvmRule schema' {
    Context 'happy path' {
        It 'accepts the minimum required keys and returns a canonical pscustomobject' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.minimum'
                    Kind        = 'FileMustExist'
                    Description = 'minimum'
                    Parameters  = @{ Path = 'terraform.tf' }
                }
                $rule = New-AvmRule -Definition $def
                $rule | Should -BeOfType ([pscustomobject])
                $rule.Id | Should -Be 'avm.test.minimum'
                $rule.Kind | Should -Be 'FileMustExist'
                $rule.Severity | Should -Be 'error'        # default
                $rule.AppliesTo | Should -Be 'root'        # default
                $rule.Source | Should -BeNullOrEmpty
            }
        }

        It 'stamps the Source field when provided' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.source-stamp'
                    Kind        = 'FileMustExist'
                    Description = 'sourced'
                    Parameters  = @{ Path = 'x.tf' }
                }
                $rule = New-AvmRule -Definition $def -Source 'C:\rules\x.psd1'
                $rule.Source | Should -Be 'C:\rules\x.psd1'
            }
        }

        It 'preserves explicit Severity and AppliesTo' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.explicit'
                    Kind        = 'DirectoryMustExist'
                    Description = 'explicit fields'
                    Severity    = 'warning'
                    AppliesTo   = 'examples'
                    Parameters  = @{ Path = 'docs' }
                }
                $rule = New-AvmRule -Definition $def
                $rule.Severity | Should -Be 'warning'
                $rule.AppliesTo | Should -Be 'examples'
            }
        }
    }

    Context 'schema violations' {
        It 'rejects a missing Id with a DataException' {
            InModuleScope 'Avm.Authoring' {
                $def = @{ Kind = 'FileMustExist'; Description = 'd'; Parameters = @{ Path = 'x' } }
                $err = $null
                try { Test-AvmRule -Definition $def } catch { $err = $_.Exception }
                $err | Should -Not -BeNullOrEmpty
                $err.GetType().Name | Should -Be 'DataException'
                $err.Message | Should -Match "missing required key 'Id'"
            }
        }

        It 'rejects an Id with uppercase characters' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'Avm.Test.Bad'
                    Kind        = 'FileMustExist'
                    Description = 'd'
                    Parameters  = @{ Path = 'x' }
                }
                { Test-AvmRule -Definition $def } | Should -Throw -ErrorId '*'
            }
        }

        It 'rejects an unknown top-level key' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.unknown'
                    Kind        = 'FileMustExist'
                    Description = 'd'
                    Parameters  = @{ Path = 'x' }
                    NotARealKey = 'hi'
                }
                $err = $null
                try { Test-AvmRule -Definition $def } catch { $err = $_.Exception }
                $err.Message | Should -Match "unknown key 'NotARealKey'"
            }
        }

        It 'rejects an unsupported Kind' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.badkind'
                    Kind        = 'TotallyMadeUp'
                    Description = 'd'
                    Parameters  = @{}
                }
                $err = $null
                try { Test-AvmRule -Definition $def } catch { $err = $_.Exception }
                $err.Message | Should -Match "Kind 'TotallyMadeUp'"
            }
        }

        It 'rejects an unsupported Severity' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.badsev'
                    Kind        = 'FileMustExist'
                    Description = 'd'
                    Severity    = 'critical'
                    Parameters  = @{ Path = 'x' }
                }
                $err = $null
                try { Test-AvmRule -Definition $def } catch { $err = $_.Exception }
                $err.Message | Should -Match "Severity 'critical'"
            }
        }

        It 'rejects an unsupported AppliesTo' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.badapplies'
                    Kind        = 'FileMustExist'
                    Description = 'd'
                    AppliesTo   = 'galaxy'
                    Parameters  = @{ Path = 'x' }
                }
                $err = $null
                try { Test-AvmRule -Definition $def } catch { $err = $_.Exception }
                $err.Message | Should -Match "AppliesTo 'galaxy'"
            }
        }

        It 'rejects a missing Parameters key' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.noparams'
                    Kind        = 'FileMustExist'
                    Description = 'd'
                }
                $err = $null
                try { Test-AvmRule -Definition $def } catch { $err = $_.Exception }
                $err.Message | Should -Match "missing required key 'Parameters'"
            }
        }

        It 'rejects FileMustNotExist without Path' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.no-path'
                    Kind        = 'FileMustNotExist'
                    Description = 'd'
                    Parameters  = @{}
                }
                $err = $null
                try { Test-AvmRule -Definition $def } catch { $err = $_.Exception }
                $err.Message | Should -Match 'FileMustNotExist requires Parameters.Path'
            }
        }

        It 'rejects FileMustNotExist with an empty FixRenameTo' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.empty-rename'
                    Kind        = 'FileMustNotExist'
                    Description = 'd'
                    Parameters  = @{ Path = 'x'; FixRenameTo = '   ' }
                }
                $err = $null
                try { Test-AvmRule -Definition $def } catch { $err = $_.Exception }
                $err.Message | Should -Match 'FixRenameTo must not be empty'
            }
        }

        It 'rejects GitignoreMustContain with an empty RequiredGlobs list' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.empty-globs'
                    Kind        = 'GitignoreMustContain'
                    Description = 'd'
                    Parameters  = @{ RequiredGlobs = @() }
                }
                $err = $null
                try { Test-AvmRule -Definition $def } catch { $err = $_.Exception }
                $err.Message | Should -Match 'must have at least one entry'
            }
        }

        It 'rejects GitignoreMustContain with a whitespace-only glob entry' {
            InModuleScope 'Avm.Authoring' {
                $def = @{
                    Id          = 'avm.test.blank-glob'
                    Kind        = 'GitignoreMustContain'
                    Description = 'd'
                    Parameters  = @{ RequiredGlobs = @('.terraform/', '   ') }
                }
                $err = $null
                try { Test-AvmRule -Definition $def } catch { $err = $_.Exception }
                $err.Message | Should -Match 'entries must be non-empty'
            }
        }
    }
}
