BeforeAll {
    $script:repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot ".." ".." ".." ".."
    )).Path
}

Describe "Repository management migration layout" {
    It "contains each required isolated surface" {
        $requiredPaths = @(
            "repository-management/managed-files/files/root"
            "repository-management/managed-files/files/alz"
            "repository-management/managed-files/files/canary"
            "repository-management/managed-files/files/canary-tooling"
            "repository-management/managed-files/config/config.json"
            "repository-management/managed-files/config/deprecated-files.json"
            "repository-management/managed-files/scripts/Test-VsCodeExtensions.ps1"
            "repository-management/repository-sync/terraform/main.tf"
            "repository-management/repository-sync/scripts/Invoke-RepositorySync.ps1"
            "repository-management/repository-sync/actions/avm-repos/action.yml"
            "repository-management/repository-sync/config/repository-metadata.csv"
            "repository-management/repository-creation/scripts/New-Repository.ps1"
            ".github/workflows/repository-management-sync.yml"
            ".github/workflows/repository-management-config-test.yml"
            ".github/workflows/repository-management-pr-cleanup.yml"
            ".github/workflows/repository-management-extension-validation.yml"
        )

        foreach ($relativePath in $requiredPaths) {
            Test-Path -LiteralPath (Join-Path $script:repoRoot $relativePath) |
                Should -BeTrue -Because "$relativePath must be migrated"
        }
    }

    It "does not retain retired source layout references" {
        $roots = @(
            (Join-Path $script:repoRoot "repository-management")
            (Join-Path $script:repoRoot ".github/workflows/repository-management-sync.yml")
            (Join-Path $script:repoRoot ".github/workflows/repository-management-config-test.yml")
            (Join-Path $script:repoRoot ".github/workflows/repository-management-pr-cleanup.yml")
            (Join-Path $script:repoRoot ".github/workflows/repository-management-extension-validation.yml")
        )
        $files = @(
            Get-ChildItem -LiteralPath $roots -Recurse -File |
                Where-Object { $_.Extension -in @(".ps1", ".tf", ".yml", ".json", ".md") }
        )
        $retiredReferences = @(
            "tf-repo-mgmt"
            "repository_sync"
            "repository-meta-data"
            "\.github/actions/avm-repos"
            "validate-vscode-extensions\.sh"
        )

        foreach ($pattern in $retiredReferences) {
            $matches = @($files | Select-String -Pattern $pattern)
            $matches | Should -BeNullOrEmpty -Because "'$pattern' belongs to the source layout"
        }
    }
}
