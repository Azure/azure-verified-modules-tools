BeforeAll {
    $repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot ".." ".." ".." ".."
    )).Path
    $script:creationScript = Get-Content -LiteralPath (
        Join-Path $repoRoot "repository-management/repository-creation/scripts/New-Repository.ps1"
    ) -Raw
    $script:toolingScript = Get-Content -LiteralPath (
        Join-Path $repoRoot "repository-management/repository-creation/scripts/Test-Tooling.ps1"
    ) -Raw
}

Describe "Repository creation isolation" {
    It "has no repository sync dependency" {
        $script:creationScript | Should -Not -Match "Invoke-RepositorySync"
        $script:creationScript | Should -Not -Match "Get-AvmLabels"
        $script:creationScript | Should -Not -Match "skipRepoSync"
        $script:creationScript | Should -Not -Match "skipCleanup"
    }

    It "updates metadata in the tooling repository" {
        $script:creationScript |
            Should -Match "Azure/azure-verified-modules-tools"
        $script:creationScript |
            Should -Match "repository-management/repository-sync/config/repository-metadata\.csv"
    }

    It "checks only creation prerequisites" {
        $script:toolingScript | Should -Match '"git", "gh"'
        $script:toolingScript | Should -Match "gh auth status"
        $script:toolingScript | Should -Not -Match "\baz\b"
        $script:toolingScript | Should -Not -Match "\bARM_"
        $script:toolingScript | Should -Not -Match "\bterraform\b"
    }
}
