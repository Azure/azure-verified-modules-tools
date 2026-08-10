#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force

    function script:NewRoot {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root | Out-Null
        return $root
    }

    function script:WriteRuleFile {
        param([string] $Path, [string] $Content)
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($Path, $Content, $utf8)
    }

    function script:NewTerraformContext {
        param([string] $Root)
        return [pscustomobject]@{ Ecosystem = 'terraform'; Root = $Root }
    }

    # Pre-stages the minimum on-disk shape (files + dirs + .gitignore) that
    # satisfies every error-severity built-in rule shipped under
    # src/Avm.Authoring/Resources/Rules/. After calling this, no built-in
    # rule should fire. Tests can then layer their own per-repo rules on top.
    function script:NewBaselineRoot {
        $root = script:NewRoot
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $root 'terraform.tf'), '# stub', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $root '_header.md'), '# header', $utf8)
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'examples/default/_header.md'), '# header', $utf8)
        New-Item -ItemType Directory -Path (Join-Path $root 'tests/unit') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'tests/unit/main.tftest.hcl'), '# test', $utf8)
        $globs = @(
            '.DS_Store', '.terraform.lock.hcl', '.terraformrc', '*.md.tmp', '*.mptfbackup',
            '*.tfstate.*', '*.tfstate', '*.tfvars.json', '*.tfvars', '**/.terraform/*',
            '*tfplan*', 'avm.tflint_example.hcl', 'avm.tflint_example.merged.hcl',
            'avm.tflint_module.hcl', 'avm.tflint_module.merged.hcl', 'avm.tflint.hcl',
            'avm.tflint.merged.hcl', 'avmmakefile', 'crash.*.log', 'crash.log',
            'examples/*/policy', 'README-generated.md', 'terraform.rc', '.avm'
        )
        [System.IO.File]::WriteAllText((Join-Path $root '.gitignore'), (($globs -join "`n") + "`n"), $utf8)
        return $root
    }
}

Describe 'Invoke-AvmTerraformCheckConvention engine' {
    It 'rejects a non-terraform context with ArgumentException' {
        $ctx = [pscustomobject]@{ Ecosystem = 'bicep'; Root = $TestDrive }
        { InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C } } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'returns the standard envelope with Tool=avm-rules/1 and ToolSource=builtin' {
        $root = script:NewRoot
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $result.Engine | Should -Be 'terraform'
        $result.Tool | Should -Be 'avm-rules/1'
        $result.ToolPath | Should -BeNullOrEmpty
        $result.ToolSource | Should -Be 'builtin'
    }

    It 'returns status=pass when only warning-severity issues fire' {
        # Baseline root satisfies every error-severity built-in rule
        # (terraform.tf, _header.md, examples/, tests/, .gitignore), so no
        # built-in rule fires. A per-repo warning-severity rule for a missing
        # file is layered on to prove a firing warning does not flip Status.
        $root = script:NewBaselineRoot
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'warn.psd1') @'
@{
    Id          = 'avm.warn.optional-file'
    Kind        = 'FileMustExist'
    Description = 'optional file is recommended'
    Severity    = 'warning'
    AppliesTo   = 'root'
    Parameters  = @{ Path = 'OPTIONAL.md' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $result.Status | Should -Be 'pass'
        $warnIssues = @($result.Issues | Where-Object Code -eq 'avm.warn.optional-file')
        $warnIssues.Count | Should -BeGreaterOrEqual 1
        $warnIssues[0].Severity | Should -Be 'warning'
    }

    It 'returns status=fail when at least one issue is severity=error' {
        $root = script:NewRoot
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'errrule.psd1') @'
@{
    Id          = 'avm.err.requires-terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'terraform.tf must exist'
    Severity    = 'error'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $result.Status | Should -Be 'fail'
        ($result.Issues | Where-Object Code -eq 'avm.err.requires-terraform-tf') | Should -Not -BeNullOrEmpty
    }

    It 'expands AppliesTo=examples into each examples/{name} subdirectory' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/second')  -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'each-example.psd1') @'
@{
    Id          = 'avm.examples.terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'each example needs terraform.tf'
    AppliesTo   = 'examples'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $exampleIssues = @($result.Issues | Where-Object Code -eq 'avm.examples.terraform-tf')
        $exampleIssues.Count | Should -Be 2
        ($exampleIssues.File | Sort-Object) | Should -Be @('examples/default/terraform.tf', 'examples/second/terraform.tf')
    }

    It 'expands AppliesTo=modules into each modules/{name} subdirectory' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'modules/private-endpoint') -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'each-module.psd1') @'
@{
    Id          = 'avm.modules.terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'each module needs terraform.tf'
    AppliesTo   = 'modules'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $modIssues = @($result.Issues | Where-Object Code -eq 'avm.modules.terraform-tf')
        $modIssues.Count | Should -Be 1
        $modIssues[0].File | Should -Be 'modules/private-endpoint/terraform.tf'
    }

    It 'AppliesTo=all walks root + examples/* + modules/*' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'modules/sub')      -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'all.psd1') @'
@{
    Id          = 'avm.all.terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'terraform.tf everywhere'
    AppliesTo   = 'all'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $issuesForRule = @($result.Issues | Where-Object Code -eq 'avm.all.terraform-tf')
        $files = ($issuesForRule.File | Sort-Object)
        $files | Should -Contain 'terraform.tf'
        $files | Should -Contain 'examples/default/terraform.tf'
        $files | Should -Contain 'modules/sub/terraform.tf'
        $issuesForRule.Count | Should -Be 3
    }

    It 'expands an AppliesTo array into exactly the named scopes' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'modules/sub')      -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'root-and-modules.psd1') @'
@{
    Id          = 'avm.scoped.terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'terraform.tf at root and in nested modules'
    AppliesTo   = @('root', 'modules')
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $files = @($result.Issues | Where-Object Code -eq 'avm.scoped.terraform-tf').File | Sort-Object
        $files | Should -Be @('modules/sub/terraform.tf', 'terraform.tf')
        $files | Should -Not -Contain 'examples/default/terraform.tf'
    }

    It 'evaluates an AppliesTo array in canonical root/examples/modules order' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'modules/sub')      -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        # Authored out of order and with a duplicate; expansion must normalise.
        script:WriteRuleFile (Join-Path $repoDir 'unordered.psd1') @'
@{
    Id          = 'avm.scoped.ordered'
    Kind        = 'FileMustExist'
    Description = 'scopes are normalised regardless of authored order'
    AppliesTo   = @('modules', 'root', 'modules')
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $files = @(@($result.Issues | Where-Object Code -eq 'avm.scoped.ordered').File)
        $files | Should -Be @('terraform.tf', 'modules/sub/terraform.tf')
    }

    Context 'F08 - the built-in terraform.tf rule ignores examples' {
        It 'does not fire for examples that have no terraform.tf' {
            $root = script:NewBaselineRoot
            New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'examples/second')  -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'examples/default/_header.md'), '# h', [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $root 'examples/second/_header.md'), '# h', [System.Text.UTF8Encoding]::new($false))

            $ctx = script:NewTerraformContext $root
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }
            @($result.Issues | Where-Object Code -eq 'avm.tf.terraform-tf-must-exist') | Should -BeNullOrEmpty
            $result.Status | Should -Be 'pass'
        }

        It 'still fires for a nested module that has no terraform.tf' {
            $root = script:NewBaselineRoot
            New-Item -ItemType Directory -Path (Join-Path $root 'modules/sub') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'modules/sub/_header.md'), '# h', [System.Text.UTF8Encoding]::new($false))

            $ctx = script:NewTerraformContext $root
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }
            $issues = @($result.Issues | Where-Object Code -eq 'avm.tf.terraform-tf-must-exist')
            $issues.Count | Should -Be 1
            $issues[0].File | Should -Be 'modules/sub/terraform.tf'
            $result.Status | Should -Be 'fail'
        }

        It 'still fires when the repository root has no terraform.tf' {
            $root = script:NewBaselineRoot
            Remove-Item -LiteralPath (Join-Path $root 'terraform.tf') -Force

            $ctx = script:NewTerraformContext $root
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }
            $issues = @($result.Issues | Where-Object Code -eq 'avm.tf.terraform-tf-must-exist')
            $issues.Count | Should -Be 1
            $issues[0].File | Should -Be 'terraform.tf'
        }

        It 'passes on a mixed repository where only examples lack terraform.tf' {
            $root = script:NewBaselineRoot
            foreach ($rel in @('examples/default', 'examples/second', 'modules/sub')) {
                New-Item -ItemType Directory -Path (Join-Path $root $rel) -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $root "$rel/_header.md"), '# h', [System.Text.UTF8Encoding]::new($false))
            }
            [System.IO.File]::WriteAllText((Join-Path $root 'modules/sub/terraform.tf'), '# stub', [System.Text.UTF8Encoding]::new($false))

            $ctx = script:NewTerraformContext $root
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }
            @($result.Issues | Where-Object Code -eq 'avm.tf.terraform-tf-must-exist') | Should -BeNullOrEmpty
            $result.Status | Should -Be 'pass'
        }
    }

    It 'emits no Issues when an AppliesTo=examples rule has no example subdirectories' {
        $root = script:NewRoot   # no examples/ at all
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'each-example.psd1') @'
@{
    Id          = 'avm.examples.requires'
    Kind        = 'FileMustExist'
    Description = 'each example needs terraform.tf'
    AppliesTo   = 'examples'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        @($result.Issues | Where-Object Code -eq 'avm.examples.requires') | Should -BeNullOrEmpty
    }

    It 'plumbs -Fix through to primitives that declare a fix path' {
        $root = script:NewRoot
        Set-Content -LiteralPath (Join-Path $root 'output.tf') -Value '# stub' -NoNewline

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'rename.psd1') @'
@{
    Id          = 'avm.fix.rename-output-tf'
    Kind        = 'FileMustNotExist'
    Description = 'output.tf must be renamed'
    Parameters  = @{ Path = 'output.tf'; FixRenameTo = 'outputs.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C -Fix | Out-Null
        }
        Test-Path -LiteralPath (Join-Path $root 'output.tf')  | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'outputs.tf') | Should -BeTrue
    }

    It 'fixes only rules with an associated fix when -FixableOnly is set' {
        $root = script:NewRoot
        Set-Content -LiteralPath (Join-Path $root 'output.tf') -Value '# stub' -NoNewline
        $ctx = script:NewTerraformContext $root

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C -Fix -FixableOnly
        }

        $result.Status | Should -Be 'pass'
        @($result.Issues).Count | Should -Be 0
        Join-Path $root 'output.tf' | Should -Not -Exist
        Join-Path $root 'outputs.tf' | Should -Exist
        Join-Path $root '_header.md' | Should -Exist
        Join-Path $root 'tests/.gitkeep' | Should -Exist
        Join-Path $root '.gitignore' | Should -Exist
        Join-Path $root 'terraform.tf' | Should -Not -Exist
        Join-Path $root 'examples' | Should -Not -Exist

        $strictResult = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $strictResult.Status | Should -Be 'fail'
        $strictResult.Issues.Code | Should -Contain 'avm.tf.terraform-tf-must-exist'
        $strictResult.Issues.Code | Should -Contain 'avm.tf.examples-dir-must-exist'
    }

    It 'emits forward-slash separators in Issue.File even on Windows-style joined paths' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'each.psd1') @'
@{
    Id          = 'avm.examples.terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'd'
    AppliesTo   = 'examples'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $issue = $result.Issues | Where-Object Code -eq 'avm.examples.terraform-tf' | Select-Object -First 1
        $issue.File | Should -Be 'examples/default/terraform.tf'
        $issue.File | Should -Not -Match '\\'
    }
}
