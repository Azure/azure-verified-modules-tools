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

    It "uses avm environment variables and only secrets the app private key" {
        $workflow = Get-Content -LiteralPath (
            Join-Path $script:repoRoot ".github/workflows/repository-management-sync.yml"
        ) -Raw
        $environmentVariables = @(
            "ARM_CLIENT_ID"
            "ARM_SUBSCRIPTION_ID"
            "ARM_TENANT_ID"
            "AVM_APP_CLIENT_ID"
            "IDENTITY_RESOURCE_GROUP_NAME"
            "MANAGEMENT_GROUP_ID"
            "STORAGE_ACCOUNT_CONTAINER_NAME"
            "STORAGE_ACCOUNT_NAME"
            "STORAGE_ACCOUNT_RESOURCE_GROUP_NAME"
            "TEST_SUBSCRIPTION_IDS"
        )

        foreach ($variable in $environmentVariables) {
            $workflow | Should -Match "\$\{\{\s*vars\.$variable\s*\}\}"
        }

        ([regex]::Matches($workflow, '(?m)^\s*environment:\s*avm\s*$')).Count |
            Should -Be 2
        $secretReferences = @(
            [regex]::Matches($workflow, 'secrets\.([A-Z0-9_]+)') |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Unique
        )
        $secretReferences | Should -Be @("AVM_APP_PRIVATE_KEY")
        $workflow | Should -Not -Match "TARGET_SUBSCRIPTION_ID"
    }

    It "keeps scheduled sync disabled during cutover with manual plan-only as the default" {
        $workflow = Get-Content -LiteralPath (
            Join-Path $script:repoRoot ".github/workflows/repository-management-sync.yml"
        ) -Raw

        $workflow | Should -Not -Match '(?m)^  schedule:\s*$'
        $workflow | Should -Match "(?m)^  # schedule:\s*$"
        $workflow | Should -Match "(?m)^  #   - cron: '33 \*/4 \* \* 1-5'\s*$"
        $workflow | Should -Match (
            '(?ms)^      plan_only:\r?\n.*?^        default:\s*true\s*$'
        )
    }
}
