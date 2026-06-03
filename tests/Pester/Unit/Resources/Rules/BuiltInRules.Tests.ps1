#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Slice D coverage for the built-in rule .psd1 modules under
# src/Avm.Authoring/Resources/Rules/. Each rule is loaded via
# Read-AvmRuleSet (which routes through New-AvmRule + Test-AvmRule),
# then per-rule assertions cover the Id / Kind / Severity / AppliesTo /
# Parameters shape. The primitives themselves are covered by their own
# Test-AvmRule*.Tests.ps1 files -- this file only proves the authored
# configuration is correct and stable.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))))
    $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    Import-Module -Name $script:moduleManifest -Force

    $script:rulesDir = Join-Path (Join-Path (Join-Path (Join-Path $script:repoRoot 'src') 'Avm.Authoring') 'Resources') 'Rules'

    # Read-AvmRuleSet is private; reach in via the module's session state
    # the same way the engine and primitive tests do.
    $script:mod = Get-Module -Name 'Avm.Authoring'

    # Load the full built-in rule set by pointing Read-AvmRuleSet at an
    # empty directory (so the per-repo overlay contributes nothing) and
    # let it walk the built-in dir on its own.
    $emptyDir = Join-Path $TestDrive 'no-overrides'
    $null = New-Item -ItemType Directory -Path $emptyDir -Force

    $script:rules = & $script:mod { param($p) Read-AvmRuleSet -Path $p } $emptyDir
    $script:rulesById = @{}
    foreach ($r in $script:rules) { $script:rulesById[$r.Id] = $r }
}

AfterAll {
    Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
}

Describe 'Built-in AVM convention rules (Slice D port of grept policies)' -Tag 'Unit' {

    Context 'Loader sees every shipped .psd1' {
        It 'loads every .psd1 under Resources/Rules/' {
            $files = @(Get-ChildItem -LiteralPath $script:rulesDir -Filter '*.psd1' -File)
            $files.Count | Should -BeGreaterThan 0
            @($script:rules).Count | Should -Be $files.Count
        }

        It 'returns rules with unique Ids' {
            $ids = @($script:rules | ForEach-Object { $_.Id })
            ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
        }

        It 'returns rules sorted by Id (ordinal)' {
            $ids = @($script:rules | ForEach-Object { $_.Id })
            $sorted = [string[]]@($ids)
            [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
            $ids | Should -Be $sorted
        }

        It 'stamps the .psd1 source path on every rule' {
            foreach ($r in $script:rules) {
                $r.Source | Should -Not -BeNullOrEmpty
                (Test-Path -LiteralPath $r.Source -PathType Leaf) | Should -BeTrue
            }
        }
    }

    Context 'Slice C smoke rule is still shipped' {
        It 'ships avm.smoke.avm-config-exists' {
            $script:rulesById.ContainsKey('avm.smoke.avm-config-exists') | Should -BeTrue
        }
    }

    Context 'Slice D ports the kept grept policies' {
        It 'ships avm.tf.outputs-tf-not-output-tf with rename fix' {
            $r = $script:rulesById['avm.tf.outputs-tf-not-output-tf']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'FileMustNotExist'
            $r.Severity | Should -Be 'error'
            $r.AppliesTo | Should -Be 'all'
            [string]$r.Parameters.Path | Should -Be 'output.tf'
            [string]$r.Parameters.FixRenameTo | Should -Be 'outputs.tf'
        }

        It 'ships avm.tf.variables-tf-not-variable-tf with rename fix' {
            $r = $script:rulesById['avm.tf.variables-tf-not-variable-tf']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'FileMustNotExist'
            $r.Severity | Should -Be 'error'
            $r.AppliesTo | Should -Be 'all'
            [string]$r.Parameters.Path | Should -Be 'variable.tf'
            [string]$r.Parameters.FixRenameTo | Should -Be 'variables.tf'
        }

        It 'ships avm.tf.terraform-tf-must-exist (root + examples + modules)' {
            $r = $script:rulesById['avm.tf.terraform-tf-must-exist']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'FileMustExist'
            $r.Severity | Should -Be 'error'
            $r.AppliesTo | Should -Be 'all'
            [string]$r.Parameters.Path | Should -Be 'terraform.tf'
            $r.Parameters.ContainsKey('FixRenameTo') | Should -BeFalse
        }

        It 'ships avm.tf.header-md-must-exist (root + examples + modules)' {
            $r = $script:rulesById['avm.tf.header-md-must-exist']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'FileMustExist'
            $r.Severity | Should -Be 'error'
            $r.AppliesTo | Should -Be 'all'
            [string]$r.Parameters.Path | Should -Be '_header.md'
        }

        It 'ships avm.tf.examples-dir-must-exist (root only)' {
            $r = $script:rulesById['avm.tf.examples-dir-must-exist']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'DirectoryMustExist'
            $r.Severity | Should -Be 'error'
            $r.AppliesTo | Should -Be 'root'
            [string]$r.Parameters.Path | Should -Be 'examples'
        }

        It 'ships avm.tf.tests-dir-must-exist (root only)' {
            $r = $script:rulesById['avm.tf.tests-dir-must-exist']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'DirectoryMustExist'
            $r.Severity | Should -Be 'error'
            $r.AppliesTo | Should -Be 'root'
            [string]$r.Parameters.Path | Should -Be 'tests'
        }

        It 'ships avm.tf.gitignore-essentials with the upstream 24-glob set' {
            $r = $script:rulesById['avm.tf.gitignore-essentials']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'GitignoreMustContain'
            $r.Severity | Should -Be 'error'
            $r.AppliesTo | Should -Be 'root'

            $globs = @($r.Parameters.RequiredGlobs)
            $globs.Count | Should -Be 24

            # Canonical entries from upstream avm-terraform-governance/grept-policies/git_ignore.grept.hcl.
            $expected = @(
                '.DS_Store',
                '.terraform.lock.hcl',
                '.terraformrc',
                '*.md.tmp',
                '*.mptfbackup',
                '*.tfstate.*',
                '*.tfstate',
                '*.tfvars.json',
                '*.tfvars',
                '**/.terraform/*',
                '*tfplan*',
                'avm.tflint_example.hcl',
                'avm.tflint_example.merged.hcl',
                'avm.tflint_module.hcl',
                'avm.tflint_module.merged.hcl',
                'avm.tflint.hcl',
                'avm.tflint.merged.hcl',
                'avmmakefile',
                'crash.*.log',
                'crash.log',
                'examples/*/policy',
                'README-generated.md',
                'terraform.rc',
                '.avm'
            )
            $globs | Should -Be $expected
        }
    }

    Context 'Every shipped rule passes the schema validator' {
        It 'New-AvmRule accepts the round-tripped definition for every rule' {
            foreach ($r in $script:rules) {
                $definition = @{
                    Id          = $r.Id
                    Kind        = $r.Kind
                    Description = $r.Description
                    Severity    = $r.Severity
                    AppliesTo   = $r.AppliesTo
                    Parameters  = $r.Parameters
                }
                $rebuilt = & $script:mod { param($d) New-AvmRule -Definition $d } $definition
                $rebuilt.Id | Should -Be $r.Id
            }
        }
    }
}
