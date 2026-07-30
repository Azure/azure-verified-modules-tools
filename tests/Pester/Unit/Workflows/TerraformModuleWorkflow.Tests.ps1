#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Static assertions over the reusable `.github/workflows/terraform-module.yml`
# workflow. There is no YAML parser dependency in this repo (see
# docs/quality-standards.md test-layer table), so this deliberately treats
# the file as text rather than adding a new third-party parsing dependency
# for four regex checks.
#
# Regression covered: a consuming module repo's `unit-test` / `pr-check` /
# `integration-test` / `e2e-test` jobs each install `Avm.Authoring` from
# PSGallery into a fresh `AVM_HOME`, but Avm.Authoring only ships the CLI —
# it does not itself install the managed tools (terraform, terraform-docs,
# tflint, conftest, mapotf, ...) pinned in `tools.lock.psd1`. Without a
# bundled-tool install step every `avm` verb that shells out to one of those
# binaries (e.g. `avm test unit`, which formats/validates with terraform)
# deterministically fails with "Tool 'terraform' (version 1.15.3) is not
# installed. Run: avm tool install." These tests pin the fix: every job that
# installs Avm.Authoring must also install the full managed-tool set via the
# shared `avm tool install` mechanism (no `-Name` filter -> installs
# everything in the lock) before it runs any `avm` command that needs them.

BeforeAll {
    $script:workflowPath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'terraform-module.yml')
    $script:workflowText = Get-Content -LiteralPath $script:workflowPath -Raw

    # One block per job, in file order, terminated by the next top-level
    # `  <job-id>:` line (two-space indent) or end of file. This is enough
    # structure to reason about step order without a full YAML parser.
    $script:jobNames = @('unit-test', 'pr-check', 'integration-test', 'e2e-test')
    $script:jobCases = @($script:jobNames | ForEach-Object { @{ JobName = $_ } })

    function script:Get-JobBlock {
        param([string] $JobName)

        $pattern = "(?ms)^  $([regex]::Escape($JobName)):.*?(?=^  [A-Za-z0-9_-]+:\s*$|\z)"
        $match = [regex]::Match($script:workflowText, $pattern)
        if (-not $match.Success) {
            throw "Could not locate job block '$JobName' in $script:workflowPath."
        }
        return $match.Value
    }
}

Describe 'terraform-module.yml reusable workflow: managed tool install' {

    It 'exists at the expected path' {
        Test-Path -LiteralPath $script:workflowPath | Should -BeTrue
    }

    It 'defines all four expected jobs' {
        foreach ($job in $script:jobNames) {
            $script:workflowText | Should -Match "(?m)^  $([regex]::Escape($job)):\s*$"
        }
    }

    Context 'job <JobName>' -ForEach $script:jobCases {
        BeforeAll {
            $script:block = Get-JobBlock -JobName $JobName
        }

        It 'installs Avm.Authoring' {
            $script:block | Should -Match '- name:\s*Install Avm\.Authoring'
        }

        It 'installs the full managed-tool set via the bare "avm tool install" mechanism' {
            $script:block | Should -Match '- name:\s*Install AVM managed tools'

            # Bare invocation only: must not regress to hard-coding a single
            # tool name (e.g. "avm tool install terraform"), which would
            # silently drop coverage for every other pinned tool.
            $script:block | Should -Match '(?m)^\s*avm tool install\s*$'
            $script:block | Should -Not -Match '(?m)avm tool install[ \t]+\S'
        }

        It 'runs the managed-tool install after Avm.Authoring and before the test/check step' {
            $installAuthoringIdx = $script:block.IndexOf('- name: Install Avm.Authoring')
            $installToolsIdx = $script:block.IndexOf('- name: Install AVM managed tools')
            $runStepIdx = [regex]::Match($script:block, '(?m)^\s*- name:\s*Run ').Index

            $installAuthoringIdx | Should -BeGreaterThan -1
            $installToolsIdx | Should -BeGreaterThan $installAuthoringIdx
            $runStepIdx | Should -BeGreaterThan $installToolsIdx
        }

        It 'imports Avm.Authoring before invoking "avm tool install"' {
            $toolsStepMatch = [regex]::Match($script:block, '(?ms)- name:\s*Install AVM managed tools.*?(?=^\s*- name:|\z)')
            $toolsStepMatch.Success | Should -BeTrue
            $toolsStepMatch.Value | Should -Match 'Import-Module Avm\.Authoring'
        }
    }

    It 'installs managed tools exactly once per job (four times total)' {
        $matches = [regex]::Matches($script:workflowText, '(?m)^\s*avm tool install\s*$')
        $matches.Count | Should -Be $script:jobNames.Count
    }
}
