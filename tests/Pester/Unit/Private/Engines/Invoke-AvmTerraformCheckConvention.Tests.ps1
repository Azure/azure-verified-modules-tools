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
    # src/Avm.Authoring/Resources/Rules/. After calling this, the only
    # built-in rule that should still fire is the warning-severity smoke
    # rule (avm.smoke.avm-config-exists), because no .avm/config.json is
    # written. Tests can then layer their own per-repo rules on top.
    function script:NewBaselineRoot {
        $root = script:NewRoot
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $root 'terraform.tf'), '# stub', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $root '_header.md'), '# header', $utf8)
        New-Item -ItemType Directory -Path (Join-Path $root 'examples') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'tests') -Force | Out-Null
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

    It 'returns status=pass when every error-severity built-in rule is satisfied (only the smoke warning fires)' {
        # Baseline root pre-stages files for the Slice D error rules
        # (terraform.tf, _header.md, examples/, tests/, .gitignore) so the
        # only built-in rule that still fires is the smoke rule. No
        # .avm/config.json is written, so the smoke rule emits a warning,
        # which must not flip Status to fail.
        $root = script:NewBaselineRoot
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $result.Status | Should -Be 'pass'
        $smokeIssues = @($result.Issues | Where-Object Code -eq 'avm.smoke.avm-config-exists')
        $smokeIssues.Count | Should -BeGreaterOrEqual 1
        $smokeIssues[0].Severity | Should -Be 'warning'
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
