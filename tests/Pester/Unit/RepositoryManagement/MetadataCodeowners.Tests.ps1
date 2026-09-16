BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $terraformRoot = Join-Path $script:root 'repository-management' 'repository-sync'
    $bicepRoot = Join-Path $script:root 'repository-management' 'bicep-codeowners-sync'
    . (Join-Path $terraformRoot 'scripts' 'lib' 'TerraformCodeowners.ps1')
    . (Join-Path $bicepRoot 'scripts' 'lib' 'Codeowners.ps1')
    $script:metadataRule = 'metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners'
    $script:templates = @{
        Terraform = Get-Content -LiteralPath (Join-Path $terraformRoot 'CODEOWNERS.template') -Raw
        Bicep = Get-Content -LiteralPath (Join-Path $bicepRoot 'CODEOWNERS.template') -Raw
    }
    $indexes = @{}
    foreach ($kind in @('res', 'ptn', 'utl')) {
        $indexes[$kind] = "ModuleName,ModuleStatus,PrimaryModuleOwnerGHHandle,SecondaryModuleOwnerGHHandle`navm/$kind/test/parent,Available,alice,`n"
    }
    $script:contents = @{
        Terraform = ConvertTo-TerraformCodeowners -Organization Azure -DefaultTeams @('module-reviewers') `
            -FileProtectionTeams @('file-reviewers') -Template $script:templates.Terraform
        Bicep = ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:templates.Bicep
    }

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
    It 'keeps both eligible review teams on one exact final rule in <Ecosystem>' -ForEach @(
        @{ Ecosystem = 'Terraform' }
        @{ Ecosystem = 'Bicep' }
    ) {
        foreach ($content in @($script:templates[$Ecosystem], $script:contents[$Ecosystem])) {
            $rules = @($content.Split("`n") | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
            $rules[-1] | Should -BeExactly $script:metadataRule
            @($rules | Where-Object { $_ -ceq $script:metadataRule }) | Should -HaveCount 1
        }
    }

    It 'assigns engineering and module owners to <Path> in both ecosystems' -ForEach @(
        @{ Path = 'metadata.json' }
        @{ Path = 'modules/child/metadata.json' }
        @{ Path = 'modules/child/modules/grandchild/metadata.json' }
        @{ Path = 'avm/res/test/parent/metadata.json' }
        @{ Path = 'avm/res/test/parent/child/metadata.json' }
        @{ Path = 'avm/res/test/parent/child/grandchild/metadata.json' }
        @{ Path = 'avm/ptn/test/parent/metadata.json' }
        @{ Path = 'avm/ptn/test/parent/child/metadata.json' }
        @{ Path = 'avm/utl/test/parent/metadata.json' }
        @{ Path = 'avm/utl/test/parent/child/metadata.json' }
        @{ Path = 'avm/res/unindexed/module/metadata.json' }
        @{ Path = '.github/metadata.json' }
        @{ Path = 'utilities/metadata.json' }
    ) {
        foreach ($ecosystem in @('Terraform', 'Bicep')) {
            $owners = @(Get-TestCodeownersForPath -Content $script:contents[$ecosystem] -Path $Path)
            $owners | Should -Be @('@Azure/azure-verified-modules-engineering-owners', '@Azure/azure-verified-modules-module-owners') -Because "$ecosystem metadata ownership must override earlier rules"
        }
    }

    It 'preserves unrelated ownership for <Ecosystem> <Path>' -ForEach @(
        @{ Ecosystem = 'Terraform'; Path = 'main.tf'; Owners = '@Azure/module-reviewers' }
        @{ Ecosystem = 'Terraform'; Path = 'modules/child/main.tf'; Owners = '@Azure/module-reviewers' }
        @{ Ecosystem = 'Terraform'; Path = '.github/CODEOWNERS'; Owners = '@Azure/file-reviewers' }
        @{ Ecosystem = 'Terraform'; Path = 'modules/child/metadata.json.bak'; Owners = '@Azure/module-reviewers' }
        @{ Ecosystem = 'Terraform'; Path = 'modules/child/other-metadata.json'; Owners = '@Azure/module-reviewers' }
        @{ Ecosystem = 'Terraform'; Path = 'modules/child/Metadata.json'; Owners = '@Azure/module-reviewers' }
        @{ Ecosystem = 'Bicep'; Path = 'README.md'; Owners = '@Azure/azure-verified-modules-tooling-contributors' }
        @{ Ecosystem = 'Bicep'; Path = '.github/CODEOWNERS'; Owners = '@Azure/azure-verified-modules-tooling-contributors' }
        @{ Ecosystem = 'Bicep'; Path = 'avm/res/test/parent/main.bicep'; Owners = '@alice @Azure/azure-verified-modules-module-owners' }
        @{ Ecosystem = 'Bicep'; Path = 'avm/res/test/parent/child/main.bicep'; Owners = '@alice @Azure/azure-verified-modules-module-owners' }
        @{ Ecosystem = 'Bicep'; Path = 'avm/res/test/parent/child/metadata.json.bak'; Owners = '@alice @Azure/azure-verified-modules-module-owners' }
        @{ Ecosystem = 'Bicep'; Path = 'avm/res/test/parent/child/other-metadata.json'; Owners = '@alice @Azure/azure-verified-modules-module-owners' }
        @{ Ecosystem = 'Bicep'; Path = 'avm/res/test/parent/child/Metadata.json'; Owners = '@alice @Azure/azure-verified-modules-module-owners' }
        @{ Ecosystem = 'Bicep'; Path = 'avm/res/test/parent/tests/avm.core.team.tests.ps1'; Owners = '@Azure/azure-verified-modules-tooling-contributors' }
        @{ Ecosystem = 'Bicep'; Path = 'avm/res/test/parent/tests/default.e2eignore'; Owners = '@Azure/azure-verified-modules-tooling-contributors' }
        @{ Ecosystem = 'Bicep'; Path = 'avm/res/unindexed/module/main.bicep'; Owners = '@Azure/azure-verified-modules-module-owners' }
    ) {
        $actual = @(Get-TestCodeownersForPath -Content $script:contents[$Ecosystem] -Path $Path)
        ($actual -join ' ') | Should -BeExactly $Owners
    }

    It 'protects metadata without introducing a default owner when Terraform team lists are empty' {
        $content = ConvertTo-TerraformCodeowners -Organization Azure -DefaultTeams @() `
            -FileProtectionTeams @() -Template $script:templates.Terraform
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
}
