#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Authoring CI platform budgets' {
    BeforeAll {
        $path = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'ci.yml'
        $workflow = Get-Content -LiteralPath $path -Raw
        $job = [regex]::Match($workflow, '(?ms)^  build:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        if (-not $job.Success) { throw 'Could not isolate the CI build job.' }
        $script:buildJob = $job.Value
    }

    It 'allows 30 minutes for Windows and 25 minutes for other test jobs' {
        $script:buildJob | Should -Match ([regex]::Escape(
                "timeout-minutes: `${{ matrix.os == 'windows-latest' && 30 || 25 }}"))
    }

    It 'keeps the complete CI gate on all three operating systems' {
        $script:buildJob | Should -Match 'os:\s*\[ubuntu-latest,\s*windows-latest,\s*macos-latest\]'
        $script:buildJob | Should -Match 'fail-fast:\s*false'
        $script:buildJob | Should -Match 'run:\s*\./build\.ps1 ci-tests'
        $script:buildJob | Should -Not -Match 'continue-on-error:\s*true'
    }
}
