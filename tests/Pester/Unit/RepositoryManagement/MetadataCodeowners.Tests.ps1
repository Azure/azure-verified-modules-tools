BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $terraformRoot = Join-Path $script:root 'repository-management' 'repository-sync'
    . (Join-Path $terraformRoot 'scripts' 'lib' 'TerraformCodeowners.ps1')
    $script:metadataRule = 'metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners'
    $script:template = Get-Content -LiteralPath (Join-Path $terraformRoot 'CODEOWNERS.template') -Raw
    $script:content = ConvertTo-TerraformCodeowners -Organization Azure -DefaultTeams @('module-reviewers') `
        -FileProtectionTeams @('file-reviewers') -Template $script:template

    function Get-TestCodeownersForPath {
        param([string] $Content, [string] $Path)

        # These templates use positive basename globs and rooted file/directory rules.
        $owners = @()
        foreach ($line in $Content.Split("`n")) {
            if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) {
                continue
            }
            $tokens = $line.Trim() -split '\s+'
            $pattern = $tokens[0]
            $expression = [regex]::Escape($pattern.TrimStart('/')).Replace('\*', '[^/]*')
            $expression = if ($pattern.Contains('/')) { '^' + $expression } else { '(?:^|/)' + $expression }
            if (-not $pattern.EndsWith('/')) {
                $expression += '$'
            }
            if ($Path -cmatch $expression) {
                $owners = @($tokens | Select-Object -Skip 1)
            }
        }
        return $owners
    }
}

Describe 'Metadata CODEOWNERS scope and last-match precedence' {
    It 'keeps both eligible review teams on one exact final rule' {
        foreach ($content in @($script:template, $script:content)) {
            $rules = @($content.Split("`n") | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
            $rules[-1] | Should -BeExactly $script:metadataRule
            @($rules | Where-Object { $_ -ceq $script:metadataRule }) | Should -HaveCount 1
        }
    }

    It 'assigns engineering and module owners to <Path>' -ForEach @(
        @{ Path = 'metadata.json' }
        @{ Path = 'modules/child/metadata.json' }
        @{ Path = 'modules/child/modules/grandchild/metadata.json' }
        @{ Path = 'avm/res/unindexed/module/metadata.json' }
        @{ Path = '.github/metadata.json' }
        @{ Path = 'utilities/metadata.json' }
    ) {
        $owners = @(Get-TestCodeownersForPath -Content $script:content -Path $Path)
        $owners | Should -Be @('@Azure/azure-verified-modules-engineering-owners', '@Azure/azure-verified-modules-module-owners') -Because 'metadata ownership must override earlier rules'
    }

    It 'preserves unrelated ownership for <Path>' -ForEach @(
        @{ Path = 'main.tf'; Owners = '@Azure/module-reviewers' }
        @{ Path = 'modules/child/main.tf'; Owners = '@Azure/module-reviewers' }
        @{ Path = '.github/CODEOWNERS'; Owners = '@Azure/file-reviewers' }
        @{ Path = 'modules/child/metadata.json.bak'; Owners = '@Azure/module-reviewers' }
        @{ Path = 'modules/child/other-metadata.json'; Owners = '@Azure/module-reviewers' }
        @{ Path = 'modules/child/Metadata.json'; Owners = '@Azure/module-reviewers' }
    ) {
        $actual = @(Get-TestCodeownersForPath -Content $script:content -Path $Path)
        ($actual -join ' ') | Should -BeExactly $Owners
    }

    It 'protects metadata without introducing a default owner when Terraform team lists are empty' {
        $content = ConvertTo-TerraformCodeowners -Organization Azure -DefaultTeams @() `
            -FileProtectionTeams @() -Template $script:template
        @(Get-TestCodeownersForPath -Content $content -Path 'modules/child/metadata.json') |
            Should -Be @('@Azure/azure-verified-modules-engineering-owners', '@Azure/azure-verified-modules-module-owners')
        @(Get-TestCodeownersForPath -Content $content -Path 'modules/child/main.tf') | Should -BeNullOrEmpty
        @(Get-TestCodeownersForPath -Content $content -Path '.github/CODEOWNERS') | Should -BeNullOrEmpty
    }
}

Describe 'Existing metadata review enforcement prerequisites' {
    It 'retains required code owner reviews and the existing App pull-request bypass in repository settings' {
        $terraformRoot = Join-Path $script:root 'repository-management' 'repository-sync' 'terraform'
        $rulesets = Get-Content -LiteralPath (Join-Path $terraformRoot 'modules' 'github' 'github.rulesets.tf') -Raw
        $rulesets | Should -Match '(?m)^\s*enforcement\s*=\s*"active"$'
        $rulesets | Should -Match '(?m)^\s*require_code_owner_review\s*=\s*true$'
        $rulesets | Should -Match '(?s)dynamic "bypass_actors".*?actor_id\s*=\s*var\.github_avm_app_id\s+actor_type\s*=\s*"Integration"\s+bypass_mode\s*=\s*"pull_request"'
        $main = Get-Content -LiteralPath (Join-Path $terraformRoot 'main.tf') -Raw
        $main | Should -Match '(?m)^\s*bypass_ruleset_for_approval_enabled\s*=\s*true$'
        $config = Get-Content -LiteralPath (Join-Path $script:root 'repository-management' 'repository-config' 'config.json') -Raw | ConvertFrom-Json
        $default = $config.repositoryGroups | Where-Object name -EQ 'default'
        $engineering = @($default.teams | Where-Object name -EQ 'azure-verified-modules-engineering-owners')
        $engineering | Should -HaveCount 1
        $engineering[0].repositoryPermission | Should -BeExactly 'push'
        $moduleOwners = @($default.teams | Where-Object name -EQ 'azure-verified-modules-module-owners')
        $moduleOwners | Should -HaveCount 1
        $moduleOwners[0].repositoryPermission | Should -BeExactly 'push'
        $moduleOwners[0].environmentApproval | Should -BeFalse
        $engineering[0].environmentApproval | Should -BeFalse
        @($default.codeOwnersFileProtectionTeams) | Should -Be @('azure-verified-modules-engineering-owners')
    }

    It 'wires configured team IDs into the existing pull-request-only ruleset bypass' {
        $terraformRoot = Join-Path $script:root 'repository-management' 'repository-sync' 'terraform'
        $rulesets = Get-Content -LiteralPath (Join-Path $terraformRoot 'modules' 'github' 'github.rulesets.tf') -Raw
        $rulesets | Should -Match '(?s)dynamic "bypass_actors" \{\s*for_each\s*=\s*toset\(var\.pull_request_bypass_teams\)\s*content \{\s*actor_id\s*=\s*data\.github_team\.this\[bypass_actors\.value\]\.id\s+actor_type\s*=\s*"Team"\s+bypass_mode\s*=\s*"pull_request"'
        $main = Get-Content -LiteralPath (Join-Path $terraformRoot 'main.tf') -Raw
        $main | Should -Match '(?m)^\s*pull_request_bypass_teams\s*=\s*var\.pull_request_bypass_teams$'
        $rootVariables = Get-Content -LiteralPath (Join-Path $terraformRoot 'variables.tf') -Raw
        $rootVariables | Should -Match '(?s)variable "pull_request_bypass_teams" \{\s*type\s*=\s*list\(string\).*?default\s*=\s*\[\]'
        $sync = Get-Content -LiteralPath (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositorySync.ps1') -Raw
        $sync | Should -Match '(?m)^\s*pull_request_bypass_teams\s*=\s*\$settings\.PullRequestBypassTeams$'
    }
}
