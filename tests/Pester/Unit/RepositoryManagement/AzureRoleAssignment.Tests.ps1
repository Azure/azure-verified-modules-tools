BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $azureRoot = Join-Path $root 'repository-management' 'repository-sync' 'terraform' 'modules' 'azure'
    $script:main = Get-Content -LiteralPath (Join-Path $azureRoot 'main.tf') -Raw
    $script:variables = Get-Content -LiteralPath (Join-Path $azureRoot 'variables.tf') -Raw
}

Describe 'Repository sync Owner delegation' {
    It 'creates no direct per-repository Owner assignment or whole shared-group resource' {
        $script:main | Should -Not -Match 'resource\s+"azapi_resource"\s+"identity_role_assignment"'
        $script:main | Should -Not -Match 'Microsoft.Authorization/roleAssignments'
        $script:main | Should -Not -Match 'resource\s+"azuread_group"\s+'
        $script:main | Should -Match 'resource\s+"azuread_group_member"\s+"test_permissions"'
    }

    It 'requires a concrete BAMI provisioning context for every identity and membership' {
        $script:variables | Should -Match '(?s)variable "expected_identity_context".*?nullable\s*=\s*false'
        $script:main | Should -Match 'lower\(self.tenant_id\) == lower\(var.expected_identity_context.tenant_id\)'
        $script:main | Should -Match 'lower\(self.client_id\) == lower\(var.expected_identity_context.controller_client_id\)'
        $script:main | Should -Match 'condition\s*=\s*local.member_is_repository_identity'
    }

    It 'never retains live BAMI direct Owner access using a forget block' {
        $script:main | Should -Not -Match 'removed\s*\{|destroy\s*=\s*false'
    }
}
