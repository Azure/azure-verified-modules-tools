BeforeAll {
    $script:repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot ".." ".." ".." ".."
    )).Path
}

Describe "Repository management migration layout" {
    It "contains each required isolated surface" {
        $requiredPaths = @(
            "repository-management/repository-config/config.json"
            "repository-management/repository-sync/terraform/main.tf"
            "repository-management/repository-sync/scripts/Invoke-RepositorySync.ps1"
            "repository-management/repository-sync/actions/avm-repos/action.yml"
            "repository-management/repository-sync/config/repository-metadata.csv"
            "repository-management/repository-creation/scripts/New-Repository.ps1"
            ".github/workflows/repository-management-sync.yml"
            ".github/workflows/repository-management-config-test.yml"
        )

        foreach ($relativePath in $requiredPaths) {
            Test-Path -LiteralPath (Join-Path $script:repoRoot $relativePath) |
                Should -BeTrue -Because "$relativePath must be migrated"
        }
    }

    It "no longer carries the legacy managed files tree" {
        # Managed files now live in Azure/azure-verified-modules-managed-files.
        # Avm.Authoring 0.8.0 resolves them from there, so the local shim that
        # served the previously released module has been retired.
        $retiredPaths = @(
            "repository-management/managed-files"
            "repository-management/managed-files/files/root"
            "repository-management/managed-files/config/config.json"
            "repository-management/managed-files/config/deprecated-files.json"
        )

        foreach ($relativePath in $retiredPaths) {
            Test-Path -LiteralPath (Join-Path $script:repoRoot $relativePath) |
                Should -BeFalse -Because "$relativePath moved to the managed files repository"
        }
    }

    It "does not retain retired source layout references" {
        $roots = @(
            (Join-Path $script:repoRoot "repository-management")
            (Join-Path $script:repoRoot ".github/workflows/repository-management-sync.yml")
            (Join-Path $script:repoRoot ".github/workflows/repository-management-config-test.yml")
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
            $found = @($files | Select-String -Pattern $pattern)
            $found | Should -BeNullOrEmpty -Because "'$pattern' belongs to the source layout"
        }
    }

    It "does not manage the retired Copilot Actions environment or secrets" {
        $terraformRoot = Join-Path $script:repoRoot "repository-management/repository-sync/terraform"
        $files = @(Get-ChildItem -LiteralPath $terraformRoot -Recurse -File -Filter "*.tf")
        $retiredReferences = @(
            'github_repository_copilot_environment_name'
            'resource\s+"github_repository_environment"\s+"copilot"'
            'resource\s+"github_actions_environment_secret"\s+"copilot_'
            'environment\s*=\s*"copilot"'
        )

        foreach ($pattern in $retiredReferences) {
            @($files | Select-String -Pattern $pattern) |
                Should -BeNullOrEmpty -Because "Copilot uses separately configured Agents secrets"
        }
    }

    It "preserves Copilot firewall configuration independently of the retired environment" {
        $terraformRoot = Join-Path $script:repoRoot "repository-management/repository-sync/terraform"
        $main = Get-Content -LiteralPath (Join-Path $terraformRoot "main.tf") -Raw
        $variables = Get-Content -LiteralPath (Join-Path $terraformRoot "variables.tf") -Raw
        $firewall = Get-Content -LiteralPath (
            Join-Path $terraformRoot "modules/github/github.repository.variables.tf"
        ) -Raw

        $main | Should -Match 'copilot_agent_firewall_allow_list\s*=\s*var\.github_copilot_agent_firewall_allow_list'
        $main | Should -Match 'copilot_agent_firewall_allow_list_variable_name\s*=\s*var\.github_copilot_agent_firewall_allow_list_variable_name'
        $variables | Should -Match 'default\s*=\s*"COPILOT_AGENT_FIREWALL_ALLOW_LIST_ADDITIONS"'
        $firewall | Should -Match 'resource\s+"github_actions_variable"\s+"copilot_firewall_allow_list"'
        $firewall | Should -Match 'variable_name\s*=\s*var\.copilot_agent_firewall_allow_list_variable_name'
        $firewall | Should -Match 'value\s*=\s*join\(",",\s*var\.copilot_agent_firewall_allow_list\)'
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

    It "runs the exact weekday sync schedule with manual plan-only as the default" {
        $workflow = Get-Content -LiteralPath (
            Join-Path $script:repoRoot ".github/workflows/repository-management-sync.yml"
        ) -Raw

        ([regex]::Matches(
                $workflow,
                "(?m)^  schedule:\r?\n    - cron: '33 \*/4 \* \* 1-5'\s*$"
            )).Count | Should -Be 1
        $workflow | Should -Match (
            "(?ms)^      repositories_to_skip:\r?\n.*?^        default:\s*''\s*$"
        )
        $workflow | Should -Match (
            '(?ms)^      plan_only:\r?\n.*?^        default:\s*true\s*$'
        )
    }

    It "passes the relocated configuration to Avm.Authoring and lets each repository resolve its own managed files" {
        $syncScript = Get-Content -LiteralPath (
            Join-Path $script:repoRoot "repository-management/repository-sync/scripts/Invoke-RepositorySync.ps1"
        ) -Raw
        $preCommitHelper = Get-Content -LiteralPath (
            Join-Path $script:repoRoot "repository-management/repository-sync/scripts/lib/AvmPreCommit.ps1"
        ) -Raw

        $syncScript | Should -Match (
            '\$repoConfigFilePath\s*=\s*"\.\./repository-config/config\.json"'
        )
        $syncScript | Should -Not -Match 'managedFilesBaseDir'
        $preCommitHelper | Should -Not -Match 'ManagedFilesLocalPath'
        $preCommitHelper | Should -Match (
            'ConfigLocalPath\s*=\s*\$repositoryConfigDir'
        )
        Test-Path -LiteralPath (
            Join-Path $script:repoRoot "scripts/Update-AvmMapotfConfig.ps1"
        ) | Should -BeFalse
    }

    It "limits the retired governance identifier to its inert exclusion and tests" {
        $retiredIdentifier = 'avm-terraform-' + 'governance'
        $grepOutput = @(
            & git -C $script:repoRoot grep -in -e $retiredIdentifier 2>$null
        )
        $allowedProductionLine = (
            '^repository-management/repository-sync/actions/avm-repos/scripts/' +
            'Get-RepositoriesWhereAppInstalled\.ps1:\d+:\s*"' +
            [regex]::Escape($retiredIdentifier) +
            '",?\s*$'
        )
        $allowedTestLine = (
            '^tests/Pester/Unit/RepositoryManagement/' +
            'RepositoryDiscovery\.Tests\.ps1:\d+:'
        )
        # Completed progress slices are an append-only audit trail, so they may
        # name the archived repository when recording where work originated.
        $allowedProgressNoteLine = '^docs/progress/[^:]+\.md:\d+:'
        $unexpectedReferences = @(
            $grepOutput |
                Where-Object {
                    $_ -notmatch $allowedProductionLine -and
                    $_ -notmatch $allowedTestLine -and
                    $_ -notmatch $allowedProgressNoteLine
                }
        )

        $LASTEXITCODE | Should -Be 0
        $grepOutput | Should -Not -BeNullOrEmpty
        $unexpectedReferences | Should -BeNullOrEmpty
    }
}
