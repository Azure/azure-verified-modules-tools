BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $lib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    . (Join-Path $lib 'TeamsAndUsers.ps1')
    . (Join-Path $lib 'RetryHelpers.ps1')
    . (Join-Path $lib 'Logging.ps1')
}

Describe 'Repository metadata owner reconciliation' {
    BeforeEach {
        $script:users = @(
            [pscustomobject]@{ login = 'first-owner'; role_name = 'admin' }
            [pscustomobject]@{ login = 'third-owner'; role_name = 'admin' }
            [pscustomobject]@{ login = 'team-owner'; role_name = 'admin' }
            [pscustomobject]@{ login = 'team-maintainer'; role_name = 'admin' }
            [pscustomobject]@{ login = 'first-owner'; role_name = 'write' }
            [pscustomobject]@{ login = 'outside-user'; role_name = 'admin' }
        )
        $script:teamFailure = $false
        Mock Invoke-GitHubCliWithRetry {
            param($commands)
            if ($commands[0].Arguments[1] -eq 'repos/Azure/test-repo/collaborators?affiliation=direct') {
                return @{ success = $true; output = $script:users }
            }
            if ($commands[0].Arguments[1] -eq 'orgs/Azure/teams/owners/members?per_page=100') {
                $commands[0].Arguments | Should -Contain '--paginate'
                $commands[0].Arguments | Should -Contain '--slurp'
                return @{
                    success = -not $script:teamFailure
                    output = @(
                        @([pscustomobject]@{ login = 'team-owner' })
                        @([pscustomobject]@{ login = 'team-maintainer' })
                    )
                }
            }
            throw "Unexpected GitHub read: $($commands[0].Arguments)"
        }
        Mock Invoke-CollaboratorRemoval { $issueLog }
        Mock Add-IssueToLog { @($issueLog) + @{ type = $type; severity = $severity; message = $message } }
        $script:parameters = @{
            orgAndRepoName = 'Azure/test-repo'
            moduleMetaData = [pscustomobject]@{ owners = @('first-owner', 'second-owner', 'third-owner', '@Azure/owners') }
            planOnly = $true
            issueLog = @()
        }
    }

    It 'preserves every named or team owner with JIT admin access, not only the first two owners' {
        $null = Remove-DirectCollaborators @script:parameters
        Should -Invoke Invoke-CollaboratorRemoval -Exactly 2
        Should -Invoke Invoke-CollaboratorRemoval -Exactly 1 -ParameterFilter { $userLogin -eq 'first-owner' -and $planOnly }
        Should -Invoke Invoke-CollaboratorRemoval -Exactly 1 -ParameterFilter { $userLogin -eq 'outside-user' }
        Should -Invoke Add-IssueToLog -Exactly 0
    }

    It 'also accepts deserialized metadata dictionaries' {
        $script:parameters.moduleMetaData = @{ owners = @('first-owner', 'third-owner', '@Azure/owners') }
        $null = Remove-DirectCollaborators @script:parameters
        Should -Invoke Invoke-CollaboratorRemoval -Exactly 2
    }

    It 'preserves case-insensitive GitHub username comparisons' {
        $script:parameters.moduleMetaData.owners = @('FIRST-OWNER', 'THIRD-OWNER', '@Azure/owners')
        $null = Remove-DirectCollaborators @script:parameters
        Should -Invoke Invoke-CollaboratorRemoval -Exactly 2
    }

    It 'skips destructive cleanup when ownership is unavailable' -TestCases @(
        @{ Metadata = $null }
        @{ Metadata = [pscustomobject]@{ moduleDisplayName = 'missing owners' } }
        @{ Metadata = @{} }
    ) {
        param($Metadata)
        $script:parameters.moduleMetaData = $Metadata
        $issues = @(Remove-DirectCollaborators @script:parameters)
        $issues | Should -HaveCount 1
        $issues[0].type | Should -BeExactly 'repo-metadata-missing'
        $issues[0].severity | Should -BeExactly 'warning'
        Should -Invoke Invoke-GitHubCliWithRetry -Exactly 0
        Should -Invoke Invoke-CollaboratorRemoval -Exactly 0
    }

    It 'does not confuse valid empty owners with unavailable ownership' {
        $script:parameters.moduleMetaData.owners = @()
        $null = Remove-DirectCollaborators @script:parameters
        Should -Invoke Invoke-CollaboratorRemoval -Exactly 6
        Should -Invoke Add-IssueToLog -Exactly 0
    }

    It 'does not remove anyone when an owning team cannot be resolved' {
        $script:teamFailure = $true
        $issues = @(Remove-DirectCollaborators @script:parameters)
        $issues | Should -HaveCount 1
        $issues[0].type | Should -BeExactly 'owner-team-fetch-failed'
        Should -Invoke Invoke-CollaboratorRemoval -Exactly 0
    }

    It 'does not fetch team members when there are no direct administrators' {
        $script:users = @([pscustomobject]@{ login = 'first-owner'; role_name = 'write' })
        $null = Remove-DirectCollaborators @script:parameters
        Should -Invoke Invoke-GitHubCliWithRetry -Exactly 1
        Should -Invoke Invoke-CollaboratorRemoval -Exactly 1
    }
}
