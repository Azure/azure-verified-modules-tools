#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Guards the staged managed-file rollout rings. The overlay pointers in
# config.json are what make a ring exist at all, and the two resolvers - the
# sync pipeline's and Avm.Authoring's drift check - must agree, or a promotion
# would be written by sync and then reported as drift by pr-check.

BeforeAll {
    $script:repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot ".." ".." ".." ".."
    )).Path

    . (Join-Path $script:repoRoot (
            "repository-management/repository-sync/scripts/lib/RepositoryConfig.ps1"
        ))

    $script:managedFilesDir = Join-Path $script:repoRoot "repository-management/managed-files"
    $script:config = Get-Content -LiteralPath (
        Join-Path $script:managedFilesDir "config/config.json"
    ) -Raw | ConvertFrom-Json

    Import-Module (Join-Path $script:repoRoot "src/Avm.Authoring/Avm.Authoring.psd1") -Force

    function script:Get-SyncOverlay {
        param([string]$RepoId)

        @((Resolve-RepositorySettings -repositoryConfig $script:config -repoId $RepoId).ManagedFilesAdditional)
    }

    function script:Get-AuthoringOverlay {
        param([string]$RepoId)

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:config; R = $RepoId } {
            param($C, $R)
            Resolve-AvmManagedFilesRepositorySetting -RepositoryConfig $C -RepoId $R
        }
        @($resolved.ManagedFilesAdditional)
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe "Staged managed-file rollout rings" {
    It "gives the example repository both canary rings, tooling last" {
        # Ring 1 authors into canary-tooling. It must win over canary so a
        # file under test overrides the wider cohort's copy during promotion.
        script:Get-SyncOverlay -RepoId "avm-ptn-example-repo" |
            Should -Be @("canary", "canary-tooling")
    }

    It "gives the other canary repositories the canary ring only" {
        $canaryGroup = @(
            $script:config.repositoryGroups | Where-Object { $_.name -eq "canary" }
        )[0]
        $others = @(
            $canaryGroup.repositories | Where-Object { $_ -ne "avm-ptn-example-repo" }
        )

        $others.Count | Should -BeGreaterThan 0
        foreach ($repoId in $others) {
            script:Get-SyncOverlay -RepoId $repoId | Should -Be @("canary")
        }
    }

    It "keeps the canary cohort membership at ten repositories" {
        # Rollouts promote by moving files between overlay directories, never by
        # editing this list. A change here means a ring was resized instead.
        $canaryGroup = @(
            $script:config.repositoryGroups | Where-Object { $_.name -eq "canary" }
        )[0]

        @($canaryGroup.repositories) | Should -HaveCount 10
        @($canaryGroup.repositories) | Should -Contain "avm-ptn-example-repo"
    }

    It "scopes the tooling ring to the example repository alone" {
        $toolingGroup = @(
            $script:config.repositoryGroups | Where-Object { $_.name -eq "canary-tooling" }
        )[0]

        @($toolingGroup.repositories) | Should -Be @("avm-ptn-example-repo")
    }

    It "leaves repositories outside the canary cohort on root files only" {
        script:Get-SyncOverlay -RepoId "avm-ptn-monitoring-amba-alz" | Should -BeNullOrEmpty
    }

    It "backs every declared overlay with a directory on disk" {
        $overlays = @(
            $script:config.repositoryGroups |
                Where-Object { $_.PSObject.Properties.Name -contains "managedFilesAdditional" } |
                ForEach-Object { $_.managedFilesAdditional } |
                Select-Object -Unique
        )

        $overlays | Should -Contain "canary"
        $overlays | Should -Contain "canary-tooling"
        foreach ($overlay in $overlays) {
            Test-Path -LiteralPath (
                Join-Path $script:managedFilesDir "files/$overlay"
            ) -PathType Container |
                Should -BeTrue -Because "overlay '$overlay' must exist to receive promoted files"
        }
    }

    It "resolves identically in the sync pipeline and the drift check" {
        # The two implementations are deliberately separate; if they diverge,
        # sync writes one set of files and pr-check demands another.
        $repoIds = @(
            $script:config.repositoryGroups |
                ForEach-Object { $_.repositories } |
                Select-Object -Unique
        )
        $repoIds += "repository-outside-every-group"

        foreach ($repoId in $repoIds) {
            $expected = script:Get-SyncOverlay -RepoId $repoId
            script:Get-AuthoringOverlay -RepoId $repoId |
                Should -Be $expected -Because "overlay order for '$repoId' must match"
        }
    }
}
