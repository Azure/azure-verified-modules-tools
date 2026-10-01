#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Sync-AvmRepositoryTeamAccess' {
    BeforeAll {
        $script:teams = @(
            [pscustomobject]@{ Slug = 'module-contributors'; Permission = 'push' }
            [pscustomobject]@{ Slug = 'module-readers'; Permission = 'triage' }
        )
    }

    It 'grants missing and lower access, reading each team directly and verifying the result' {
        $results = InModuleScope 'Avm.Authoring' -Parameters @{ Teams = $script:teams } {
            param($Teams)
            $script:access = @{ 'module-readers' = @{ pull = $true } }
            Mock Invoke-AvmGitHubApi {
                $slug = ($Endpoint -split '/')[3]
                if (-not $script:access.ContainsKey($slug)) { return $null }
                @{ role_name = 'x'; permissions = $script:access[$slug] }
            } -ParameterFilter { $Method -ne 'PUT' -and $Endpoint -like 'orgs/Azure/teams/*/repos/Azure/repo' }
            Mock Invoke-AvmGitHubApi {
                $slug = ($Endpoint -split '/')[3]
                $script:access[$slug] = @{ pull = $true; triage = $true; push = ($Body.permission -eq 'push') }
            } -ParameterFilter { $Method -eq 'PUT' }
            Mock Invoke-AvmGitHubApi { throw "Unexpected call: $Method $Endpoint" }

            Sync-AvmRepositoryTeamAccess -Organization 'Azure' -Repository 'repo' -Team $Teams -Confirm:$false

            Should -Invoke Invoke-AvmGitHubApi -Exactly 4 -ParameterFilter {
                $Method -ne 'PUT' -and $Accept -eq 'application/vnd.github.v3.repository+json' -and $AllowNotFound
            }
            Should -Invoke Invoke-AvmGitHubApi -Exactly 1 -ParameterFilter {
                $Method -eq 'PUT' -and $Endpoint -eq 'orgs/Azure/teams/module-contributors/repos/Azure/repo' -and
                $Body.permission -eq 'push'
            }
            Should -Invoke Invoke-AvmGitHubApi -Exactly 1 -ParameterFilter {
                $Method -eq 'PUT' -and $Endpoint -eq 'orgs/Azure/teams/module-readers/repos/Azure/repo' -and
                $Body.permission -eq 'triage'
            }
        }

        @($results).Count | Should -Be 2
        $results[0].Status | Should -Be 'granted'
        $results[0].Previous | Should -BeNullOrEmpty
        $results[1].Status | Should -Be 'granted'
        $results[1].Previous | Should -Be 'pull'
    }

    It 'leaves <Previous> access unchanged for a push request' -TestCases @(
        @{ Previous = 'push'; Permissions = @{ pull = $true; triage = $true; push = $true } }
        @{ Previous = 'maintain'; Permissions = @{ pull = $true; triage = $true; push = $true; maintain = $true } }
        @{ Previous = 'admin'; Permissions = @{ pull = $true; push = $true; maintain = $true; admin = $true } }
        @{ Previous = 'unknown'; Permissions = $null }
    ) {
        param($Previous, $Permissions)
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Permissions = $Permissions } {
            param($Permissions)
            Mock Invoke-AvmGitHubApi -MockWith ({ @{ role_name = 'custom'; permissions = $Permissions } }.GetNewClosure())
            Sync-AvmRepositoryTeamAccess -Organization 'Azure' -Repository 'repo' -Confirm:$false `
                -Team @([pscustomobject]@{ Slug = 'module-contributors'; Permission = 'push' })
            Should -Invoke Invoke-AvmGitHubApi -Exactly 0 -ParameterFilter { $Method -eq 'PUT' }
        }
        $result.Status | Should -Be 'unchanged'
        $result.Previous | Should -Be $Previous
    }

    It 'fails when GitHub does not report the granted access' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmGitHubApi { $null } -ParameterFilter { $Method -ne 'PUT' }
            Mock Invoke-AvmGitHubApi {} -ParameterFilter { $Method -eq 'PUT' }
            {
                Sync-AvmRepositoryTeamAccess -Organization 'Azure' -Repository 'repo' -Confirm:$false `
                    -Team @([pscustomobject]@{ Slug = 'module-readers'; Permission = 'triage' })
            } | Should -Throw '*Could not verify triage access for team module-readers on Azure/repo*'
        }
    }

    It 'reports needed grants without changing access for PlanOnly and WhatIf' {
        InModuleScope 'Avm.Authoring' -Parameters @{ Teams = $script:teams } {
            param($Teams)
            Mock Invoke-AvmGitHubApi { $null } -ParameterFilter { $Method -ne 'PUT' }
            Mock Invoke-AvmGitHubApi { throw "Unexpected call: $Method $Endpoint" }

            @(Sync-AvmRepositoryTeamAccess -Organization 'Azure' -Repository 'repo' -Team $Teams -PlanOnly).Status |
                Should -Be @('planned', 'planned')
            @(Sync-AvmRepositoryTeamAccess -Organization 'Azure' -Repository 'repo' -Team $Teams -WhatIf).Status |
                Should -Be @('planned', 'planned')
        }
    }

    It 'rejects an unsupported requested permission' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmGitHubApi {}
            {
                Sync-AvmRepositoryTeamAccess -Organization 'Azure' -Repository 'repo' -Confirm:$false `
                    -Team @([pscustomobject]@{ Slug = 'team'; Permission = 'write' })
            } | Should -Throw "*Unsupported team permission 'write'*"
            Should -Invoke Invoke-AvmGitHubApi -Exactly 0
        }
    }
}
