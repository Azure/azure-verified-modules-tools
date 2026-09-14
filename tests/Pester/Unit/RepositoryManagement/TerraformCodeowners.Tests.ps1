BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:syncRoot = Join-Path $script:repoRoot 'repository-management' 'repository-sync'
    . (Join-Path $script:syncRoot 'scripts' 'lib' 'TerraformCodeowners.ps1')
    . (Join-Path $script:syncRoot 'scripts' 'lib' 'RepositoryConfig.ps1')
    $script:template = Get-Content -LiteralPath (Join-Path $script:syncRoot 'CODEOWNERS.template') -Raw
    $script:header = @(
        '# This file is managed by azure-verified-modules-tools. Do not edit manually.'
        '# Template: https://github.com/Azure/azure-verified-modules-tools/blob/main/repository-management/repository-sync/CODEOWNERS.template'
    ) -join "`n"
}

Describe 'Terraform CODEOWNERS rendering' {
    It 'renders only the configured rules for <Scenario>' -ForEach @(
        @{ Scenario = 'default and protection teams'; DefaultTeams = @('module-owners'); ProtectionTeams = @('engineering-owners'); Rules = @('* @Azure/module-owners', '.github/CODEOWNERS @Azure/engineering-owners') }
        @{ Scenario = 'protection teams only'; DefaultTeams = @(); ProtectionTeams = @('engineering-owners'); Rules = @('.github/CODEOWNERS @Azure/engineering-owners') }
        @{ Scenario = 'default teams only'; DefaultTeams = @('module-owners'); ProtectionTeams = @(); Rules = @('* @Azure/module-owners') }
        @{ Scenario = 'explicitly empty teams'; DefaultTeams = @(); ProtectionTeams = @(); Rules = @() }
        @{ Scenario = 'multiple and duplicate teams'; DefaultTeams = @('one', 'two', 'one'); ProtectionTeams = @('three', 'four', 'three'); Rules = @('* @Azure/one @Azure/two', '.github/CODEOWNERS @Azure/three @Azure/four') }
    ) {
        $content = ConvertTo-TerraformCodeowners -Organization Azure -DefaultTeams $DefaultTeams `
            -FileProtectionTeams $ProtectionTeams -Template $script:template
        $expected = $script:header
        if ($Rules.Count -gt 0) { $expected += "`n`n" + ($Rules -join "`n") }
        $content | Should -BeExactly ($expected + "`n")
        $content | Should -Not -Match '__AVM_CODEOWNERS_RULES__'
        $content | Should -Not -Match ('avm-terraform-' + 'governance')
    }

    It 'qualifies configured teams with the target organization rather than Azure' {
        $content = ConvertTo-TerraformCodeowners -Organization Contoso -DefaultTeams @('module-reviewers') `
            -FileProtectionTeams @('security-reviewers') -Template $script:template
        $content | Should -BeExactly ($script:header + "`n`n* @Contoso/module-reviewers`n.github/CODEOWNERS @Contoso/security-reviewers`n")
    }

    It 'rejects invalid team slugs in <Setting>' -ForEach @(
        @{ Setting = 'default owners'; DefaultTeams = @("team`n* @unexpected"); ProtectionTeams = @('valid-team') }
        @{ Setting = 'file protection'; DefaultTeams = @('valid-team'); ProtectionTeams = @('team other-team') }
        @{ Setting = 'qualified team input'; DefaultTeams = @('@Other/team'); ProtectionTeams = @() }
    ) {
        { ConvertTo-TerraformCodeowners -Organization Azure -DefaultTeams $DefaultTeams `
            -FileProtectionTeams $ProtectionTeams -Template $script:template } | Should -Throw '*team slug*'
    }

    It 'rejects empty team entries at parameter binding' {
        { ConvertTo-TerraformCodeowners -Organization Azure -DefaultTeams @('') `
            -FileProtectionTeams @('valid-team') -Template $script:template } | Should -Throw '*empty string*'
    }

    It 'rejects an invalid organization instead of emitting an owner token' {
        { ConvertTo-TerraformCodeowners -Organization 'Azure/team' -DefaultTeams @('owners') `
            -FileProtectionTeams @() -Template $script:template } | Should -Throw
    }

    It 'rejects a malformed template with <Mutation>' -ForEach @(
        @{ Mutation = 'missing placeholder' }
        @{ Mutation = 'duplicate placeholder' }
        @{ Mutation = 'inline placeholder' }
        @{ Mutation = 'CRLF endings' }
        @{ Mutation = 'no final newline' }
        @{ Mutation = 'a BOM' }
    ) {
        $template = switch ($Mutation) {
            'missing placeholder' { $script:template.Replace('__AVM_CODEOWNERS_RULES__', '') }
            'duplicate placeholder' { $script:template + "__AVM_CODEOWNERS_RULES__`n" }
            'inline placeholder' { $script:template.Replace('__AVM_CODEOWNERS_RULES__', 'prefix __AVM_CODEOWNERS_RULES__') }
            'CRLF endings' { $script:template.Replace("`n", "`r`n") }
            'no final newline' { $script:template.TrimEnd("`n") }
            'a BOM' { ([string][char]0xFEFF) + $script:template }
        }
        { ConvertTo-TerraformCodeowners -Organization Azure -DefaultTeams @('owners') `
            -FileProtectionTeams @('reviewers') -Template $template } | Should -Throw '*template*'
    }
}

Describe 'Repository-specific Terraform ownership configuration' {
    It 'combines wildcard, overlapping and repository-specific owners without leaking unrelated groups' {
        $config = [pscustomobject]@{
            repositoryGroups = @(
                [pscustomobject]@{
                    name = 'default'; repositories = @('*')
                    codeOwnersTeams = @('global-reviewers')
                    codeOwnersFileProtectionTeams = @('engineering-owners')
                }
                [pscustomobject]@{
                    name = 'product'; repositories = @('module-a', 'module-b')
                    codeOwnersTeams = @('product-reviewers')
                    codeOwnersFileProtectionTeams = @('product-admins')
                }
                [pscustomobject]@{
                    name = 'specific'; repositories = @('module-a')
                    codeOwnersTeams = @('module-reviewers', 'product-reviewers')
                    codeOwnersFileProtectionTeams = @('engineering-owners', 'module-admins')
                }
                [pscustomobject]@{
                    name = 'unrelated'; repositories = @('module-c')
                    codeOwnersTeams = @('unrelated-reviewers')
                    codeOwnersFileProtectionTeams = @('unrelated-admins')
                }
            )
        }
        $settings = Resolve-RepositorySettings -repositoryConfig $config -repoId 'module-a'
        $content = ConvertTo-TerraformCodeowners -Organization Contoso -DefaultTeams $settings.CodeOwnersDefaultTeams `
            -FileProtectionTeams $settings.CodeOwnersFileProtectionTeams -Template $script:template
        $content | Should -BeExactly ($script:header + @"


* @Contoso/global-reviewers @Contoso/product-reviewers @Contoso/module-reviewers
.github/CODEOWNERS @Contoso/engineering-owners @Contoso/product-admins @Contoso/module-admins

"@)
    }

    It 'applies the checked-in configuration to <Repository>' -ForEach @(
        @{ Repository = 'avm-ptn-example-repo'; RequireDefault = $true }
        @{ Repository = 'avm-res-devopsinfrastructure-pool'; RequireDefault = $false }
        @{ Repository = 'unlisted-module'; RequireDefault = $false }
    ) {
        $config = Get-Content -LiteralPath (Join-Path $script:repoRoot 'repository-management' 'repository-config' 'config.json') -Raw | ConvertFrom-Json
        $settings = Resolve-RepositorySettings -repositoryConfig $config -repoId $Repository
        $content = ConvertTo-TerraformCodeowners -Organization Azure -DefaultTeams $settings.CodeOwnersDefaultTeams `
            -FileProtectionTeams $settings.CodeOwnersFileProtectionTeams -Template $script:template
        $content | Should -Match '(?m)^\.github/CODEOWNERS @Azure/azure-verified-modules-engineering-owners$'
        ($content -cmatch '(?m)^\* @Azure/azure-verified-modules-engineering-owners$') | Should -Be $RequireDefault
    }

    It 'keeps ownership inputs out of the retired Terraform file-management path' {
        $files = Get-ChildItem -LiteralPath (Join-Path $script:syncRoot 'terraform') -Recurse -File -Filter '*.tf'
        @($files | Select-String -Pattern 'codeowners_(default|file_protection)_teams') | Should -BeNullOrEmpty
        $retiredState = Get-Content -LiteralPath (Join-Path $script:syncRoot 'terraform' 'modules' 'github' 'github.repository.removed_managed_files.tf') -Raw
        $retiredState | Should -Match '(?s)from = github_repository_file\.codeowners.*?destroy = false'
    }
}
