BeforeAll {
    $script:repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot ".." ".." ".." ".."
    )).Path
    $script:repositoryTerraform = Get-Content -LiteralPath (
        Join-Path $script:repoRoot (
            "repository-management/repository-sync/terraform/modules/github/github.repository.tf"
        )
    ) -Raw
    $script:rulesetsTerraform = Get-Content -LiteralPath (
        Join-Path $script:repoRoot (
            "repository-management/repository-sync/terraform/modules/github/github.rulesets.tf"
        )
    ) -Raw
}

Describe "Repository descriptions" {
    It "caps the generated description at the GitHub limit" {
        $script:repositoryTerraform | Should -Match (
            'github_repository_description\s*=\s*substr\(.+,\s*0,\s*350\)'
        )
    }

}

Describe "Repository merge methods" {
    It "allows only squash merges in the repository and branch ruleset" {
        $script:repositoryTerraform | Should -Match (
            'allow_merge_commit\s*=\s*false'
        )
        $script:repositoryTerraform | Should -Match (
            'allow_squash_merge\s*=\s*true'
        )
        $script:repositoryTerraform | Should -Match (
            'allow_rebase_merge\s*=\s*false'
        )
        $script:rulesetsTerraform | Should -Match (
            'allowed_merge_methods\s*=\s*\["squash"\]'
        )
    }

    It "limits the AVM App bypass to pull requests" {
        $script:rulesetsTerraform | Should -Match (
            'bypass_mode\s*=\s*"pull_request"'
        )
        $script:rulesetsTerraform | Should -Not -Match (
            'bypass_mode\s*=\s*"always"'
        )
    }
}
