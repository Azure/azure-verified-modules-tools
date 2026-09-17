BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $azureRoot = Join-Path $repoRoot 'repository-management' 'repository-sync' 'terraform' 'modules' 'azure'
    $main = Get-Content -LiteralPath (Join-Path $azureRoot 'main.tf') -Raw
    $locals = Get-Content -LiteralPath (Join-Path $azureRoot 'locals.tf') -Raw

    $assignments = [regex]::Matches(
        $main,
        '(?ms)^resource\s+"azapi_resource"\s+"identity_role_assignment"\s*\{(?<body>.*?)^\}'
    )
    $assignments.Count | Should -Be 1
    $script:assignment = $assignments[0].Groups['body'].Value

    $ownerDefinitions = [regex]::Matches(
        $locals,
        '(?m)^\s*role_definition_name_owner\s*=\s*"(?<id>[0-9a-fA-F-]+)"\s*$'
    )
    $ownerDefinitions.Count | Should -Be 1
    $script:ownerRoleId = $ownerDefinitions[0].Groups['id'].Value

    $conditions = [regex]::Matches(
        $script:assignment,
        '(?ms)^\s*condition\s*=\s*<<CONDITION\r?\n(?<value>.*?)^CONDITION\r?$'
    )
    $conditions.Count | Should -Be 1
    $condition = $conditions[0].Groups['value'].Value.Replace(
        '${local.role_definition_name_owner}', $script:ownerRoleId
    )

    $conditionPattern = (
        '\A\(\(!\(ActionMatches\{''Microsoft\.Authorization/roleAssignments/write''\}\)\)OR' +
        '\(@Request\[Microsoft\.Authorization/roleAssignments:RoleDefinitionId\]' +
        'ForAnyOfAllValues:GuidNotEquals\{(?<write>[0-9a-fA-F,-]+)\}\)\)' +
        'AND' +
        '\(\(!\(ActionMatches\{''Microsoft\.Authorization/roleAssignments/delete''\}\)\)OR' +
        '\(@Resource\[Microsoft\.Authorization/roleAssignments:RoleDefinitionId\]' +
        'ForAnyOfAllValues:GuidNotEquals\{(?<delete>[0-9a-fA-F,-]+)\}\)\)\z'
    )
    $script:conditionMatch = [regex]::Match(($condition -replace '\s', ''), $conditionPattern)
}

Describe 'Repository sync Owner delegation' {
    It 'retains the conditioned Owner role assignment' {
        $script:ownerRoleId | Should -Be '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
        $script:assignment | Should -Match (
            'roleDefinitionId\s*=\s*"/providers/Microsoft.Authorization/roleDefinitions/' +
            '\$\{local.role_definition_name_owner\}"'
        )
        $script:assignment | Should -Match 'conditionVersion\s*=\s*"2\.0"'
    }

    It 'requires both exclusion gates while leaving unrelated actions unrestricted' {
        $script:conditionMatch.Success | Should -BeTrue
    }

    Context '<Action> role assignments' -ForEach @(
        @{ Action = 'write' }
        @{ Action = 'delete' }
    ) {
        BeforeAll {
            $script:conditionMatch.Success | Should -BeTrue
            $deniedRoleIds = @($script:conditionMatch.Groups[$Action].Value -split ',')
        }

        It 'denies <RoleName>' -TestCases @(
            @{ RoleName = 'Owner'; RoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' }
            @{ RoleName = 'User Access Administrator'; RoleId = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9' }
            @{ RoleName = 'Role Based Access Control Administrator'; RoleId = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168' }
        ) {
            $deniedRoleIds | Should -Contain $RoleId
        }

        It 'excludes exactly three role definitions' {
            $deniedRoleIds.Count | Should -Be 3
        }

        It 'allows ordinary <RoleName> assignments' -TestCases @(
            @{ RoleName = 'Contributor'; RoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c' }
            @{ RoleName = 'Reader'; RoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7' }
        ) {
            $deniedRoleIds | Should -Not -BeNullOrEmpty
            $deniedRoleIds | Should -Not -Contain $RoleId
        }
    }
}
