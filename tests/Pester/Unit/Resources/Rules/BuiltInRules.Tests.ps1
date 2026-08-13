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

    Context 'Slice D ports the kept grept policies' {
        It 'ships avm.tf.outputs-tf-not-output-tf with rename fix' {
            $r = $script:rulesById['avm.tf.outputs-tf-not-output-tf']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'FileMustNotExist'
            $r.Severity | Should -Be 'error'
            @($r.AppliesTo) | Should -Be @('root', 'examples', 'modules')
            [string]$r.Parameters.Path | Should -Be 'output.tf'
            [string]$r.Parameters.FixRenameTo | Should -Be 'outputs.tf'
        }

        It 'ships avm.tf.variables-tf-not-variable-tf with rename fix' {
            $r = $script:rulesById['avm.tf.variables-tf-not-variable-tf']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'FileMustNotExist'
            $r.Severity | Should -Be 'error'
            @($r.AppliesTo) | Should -Be @('root', 'examples', 'modules')
            [string]$r.Parameters.Path | Should -Be 'variable.tf'
            [string]$r.Parameters.FixRenameTo | Should -Be 'variables.tf'
        }

        It 'ships avm.tf.terraform-tf-must-exist scoped to root + modules only' {
            $r = $script:rulesById['avm.tf.terraform-tf-must-exist']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'FileMustExist'
            $r.Severity | Should -Be 'error'
            @($r.AppliesTo) | Should -Be @('root', 'modules')
            @($r.AppliesTo) | Should -Not -Contain 'examples'
            [string]$r.Parameters.Path | Should -Be 'terraform.tf'
            $r.Parameters.ContainsKey('FixRenameTo') | Should -BeFalse
        }

        It 'ships avm.tf.header-md-must-exist (root + examples + modules)' {
            $r = $script:rulesById['avm.tf.header-md-must-exist']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'FileMustExist'
            $r.Severity | Should -Be 'error'
            @($r.AppliesTo) | Should -Be @('root', 'examples', 'modules')
            [string]$r.Parameters.Path | Should -Be '_header.md'
            [string]$r.Parameters.FixContentTemplate | Should -Be '# {DirectoryTitle}'
        }

        It 'ships avm.tf.examples-dir-must-exist with at least one example required' {
            $r = $script:rulesById['avm.tf.examples-dir-must-exist']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'DirectoryMustExist'
            $r.Severity | Should -Be 'error'
            $r.AppliesTo | Should -Be 'root'
            [string]$r.Parameters.Path | Should -Be 'examples'
            [int]$r.Parameters.MinimumChildDirectories | Should -Be 1
        }

        It 'ships avm.tf.tests-dir-must-exist with a placeholder fix' {
            $r = $script:rulesById['avm.tf.tests-dir-must-exist']
            $r | Should -Not -BeNullOrEmpty
            $r.Kind | Should -Be 'DirectoryMustExist'
            $r.Severity | Should -Be 'error'
            $r.AppliesTo | Should -Be 'root'
            [string]$r.Parameters.Path | Should -Be 'tests'
            [string]$r.Parameters.FixCreateFile | Should -Be '.gitkeep'
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
