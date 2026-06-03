#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force

    function script:WriteLfFile {
        param([string] $Path, [string[]] $Lines)
        $content = ($Lines -join "`n") + "`n"
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($Path, $content, $utf8)
    }

    function script:NewGitignoreRule {
        param([string[]] $Globs, [string] $Severity = 'error')
        InModuleScope 'Avm.Authoring' -Parameters @{ G = $Globs; S = $Severity } {
            param($G, $S)
            New-AvmRule -Definition @{
                Id          = 'avm.test.gitignore'
                Kind        = 'GitignoreMustContain'
                Description = 'required globs'
                Severity    = $S
                Parameters  = @{ RequiredGlobs = $G }
            }
        }
    }
}

Describe 'Test-AvmRuleGitignoreMustContain primitive' {
    BeforeEach {
        $script:tmp = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
        $script:gi = Join-Path $script:tmp '.gitignore'
    }

    It 'returns fail when .gitignore is absent (one issue per required glob)' {
        $rule = script:NewGitignoreRule @('.terraform/', '*.tfstate')
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleGitignoreMustContain -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'fail'
        @($result.Issues).Count | Should -Be 2
        ($result.Issues.Code | Select-Object -Unique) | Should -Be 'avm.test.gitignore'
        ($result.Issues.File | Select-Object -Unique) | Should -Be '.gitignore'
    }

    It 'returns pass when every required glob is present on its own line' {
        script:WriteLfFile $script:gi @('# managed by avm', '.terraform/', '*.tfstate', '*.tfstate.backup')
        $rule = script:NewGitignoreRule @('.terraform/', '*.tfstate')
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleGitignoreMustContain -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'pass'
        @($result.Issues).Count | Should -Be 0
    }

    It 'reports only the missing globs' {
        script:WriteLfFile $script:gi @('.terraform/')
        $rule = script:NewGitignoreRule @('.terraform/', '*.tfstate')
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleGitignoreMustContain -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'fail'
        @($result.Issues).Count | Should -Be 1
        $result.Issues[0].Message | Should -Match "missing required glob '\*\.tfstate'"
    }

    It 'does not let a comment satisfy a required glob' {
        script:WriteLfFile $script:gi @('# .terraform/   <- not a real entry')
        $rule = script:NewGitignoreRule @('.terraform/')
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleGitignoreMustContain -Rule $R -TargetRoot $T
        }
        $result.Status | Should -Be 'fail'
        @($result.Issues).Count | Should -Be 1
    }

    It 'appends missing globs when -Fix is set, preserving existing lines' {
        script:WriteLfFile $script:gi @('# managed by avm', '.terraform/')
        $rule = script:NewGitignoreRule @('.terraform/', '*.tfstate')
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleGitignoreMustContain -Rule $R -TargetRoot $T -Fix
        }
        $result.Status | Should -Be 'fixed'
        $result.FilesChanged | Should -Be 1

        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $raw = [System.IO.File]::ReadAllText($script:gi, $utf8)
        $raw | Should -Be "# managed by avm`n.terraform/`n*.tfstate`n"
    }

    It 'creates the file from scratch when -Fix is set and .gitignore is absent' {
        $rule = script:NewGitignoreRule @('.terraform/', '*.tfstate')
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleGitignoreMustContain -Rule $R -TargetRoot $T -Fix
        }
        $result.Status | Should -Be 'fixed'

        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $raw = [System.IO.File]::ReadAllText($script:gi, $utf8)
        $raw | Should -Be ".terraform/`n*.tfstate`n"
    }

    It 'normalises CRLF input to LF on fix-write' {
        $crlf = "# managed by avm`r`n.terraform/`r`n"
        [System.IO.File]::WriteAllText($script:gi, $crlf, [System.Text.UTF8Encoding]::new($false))
        $rule = script:NewGitignoreRule @('.terraform/', '*.tfstate')
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleGitignoreMustContain -Rule $R -TargetRoot $T -Fix | Out-Null
        }
        $raw = [System.IO.File]::ReadAllText($script:gi, [System.Text.UTF8Encoding]::new($false))
        $raw | Should -Not -Match "`r"
        $raw | Should -Be "# managed by avm`n.terraform/`n*.tfstate`n"
    }

    It 'propagates the rule Severity into the emitted Issue' {
        $rule = script:NewGitignoreRule @('.terraform/') -Severity 'warning'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $rule; T = $script:tmp } {
            param($R, $T)
            Test-AvmRuleGitignoreMustContain -Rule $R -TargetRoot $T
        }
        $result.Issues[0].Severity | Should -Be 'warning'
    }
}
