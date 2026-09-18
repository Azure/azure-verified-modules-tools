# Reconciliation of GitHub teams and direct collaborators against the
# configured team mapping for the repository.

# Verifies every team referenced by the repo's config actually exists in the
# org, and returns a map keyed by team slug that the github Terraform module
# consumes via `var.github_teams`.
#
# Returns @{ GithubTeams = $hashtable; IssueLog = $array }.
function Resolve-GitHubTeams {
    param(
        [string]$orgName,
        [string]$orgAndRepoName,
        [array]$teams,
        [array]$issueLog
    )

    $githubTeams = @{}

    foreach ($team in $teams) {
        $teamExists = $false
        $teamName = $team.name

        $existingTeam = Invoke-GitHubCliWithRetry `
            -commands @(
                @{
                    Arguments = @("api", "orgs/$orgName/teams/$($teamName)")
                    OutputLog = "team-exists.json"
                }
            ) `
            -returnOutputParsedFromJson

        if (!$existingTeam.success) {
            Write-Warning "Failed to check if team exists: $($teamName)."
            $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "team-check-failed" -message "Failed to check if team $teamName exists." -data $null -issueLog $issueLog
            exit 1
        }

        $teamExists = $existingTeam.output.slug -and $existingTeam.output.slug -eq $teamName

        if (!$teamExists) {
            Write-Warning "Team does not exist: $($teamName)"
            $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "team-missing" -message "Team $teamName does not exist." -data $teamName -issueLog $issueLog
        } else {
            Write-Host "Team exists: $($teamName)"
            $githubTeams[$teamName] = @{
                slug                         = $teamName
                description                  = $teamDescription
                repository_access_permission = $team.repositoryPermission
                environment_approval         = $team.environmentApproval
                members_are_team_maintainers = $team.membersAreTeamMaintainers
            }
        }
    }

    return @{
        GithubTeams = $githubTeams
        IssueLog    = $issueLog
    }
}

# Removes direct (non-team) collaborators from the repo. Module owners that
# are JIT-elevated are skipped.
function Remove-DirectCollaborators {
    param(
        [string]$orgAndRepoName,
        [object]$moduleMetaData,
        [bool]$planOnly,
        [array]$issueLog
    )

    $hasOwners = if ($moduleMetaData -is [System.Collections.IDictionary]) {
        $moduleMetaData.Contains('owners')
    } else {
        $null -ne $moduleMetaData -and $null -ne $moduleMetaData.PSObject.Properties['owners']
    }
    if (-not $hasOwners) {
        $message = "Skipping direct collaborator cleanup for $orgAndRepoName because metadata.json ownership is unavailable."
        Write-Warning $message
        return Add-IssueToLog -orgAndRepoName $orgAndRepoName -type 'repo-metadata-missing' `
            -message $message -data $null -issueLog $issueLog -severity warning
    }
    $allowedUsers = @($moduleMetaData.owners | Where-Object { -not $_.StartsWith('@') })
    $ownerTeams = @($moduleMetaData.owners | Where-Object { $_.StartsWith('@') })

    Write-Host "Checking repository: $orgAndRepoName for existing users."
    $repoUsers = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "repos/$orgAndRepoName/collaborators?affiliation=direct")
                OutputLog = "repo-users.json"
            }
        ) `
        -returnOutputParsedFromJson

    if (!$repoUsers.success) {
        Write-Warning "Failed to get repository users for: $orgAndRepoName. Skipping."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "repo-users-fetch-failed" -message "Failed to fetch repository users for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    if (@($repoUsers.output | Where-Object { $_.role_name -eq 'admin' }).Count -gt 0) {
        foreach ($ownerTeam in $ownerTeams) {
            $teamParts = $ownerTeam.TrimStart('@').Split('/')
            $members = Invoke-GitHubCliWithRetry -commands @(
                @{
                    Arguments = @('api', "orgs/$($teamParts[0])/teams/$($teamParts[1])/members?per_page=100", '--paginate', '--slurp')
                    OutputLog = "owner-team-$($teamParts[0])-$($teamParts[1]).json"
                }
            ) -returnOutputParsedFromJson
            if (-not $members.success) {
                $message = "Skipping direct collaborator cleanup for $orgAndRepoName because owners in $ownerTeam could not be resolved."
                Write-Warning $message
                return Add-IssueToLog -orgAndRepoName $orgAndRepoName -type 'owner-team-fetch-failed' `
                    -message $message -data $ownerTeam -issueLog $issueLog
            }
            foreach ($page in $members.output) {
                $allowedUsers += @($page | ForEach-Object { $_.login })
            }
        }
    }

    Write-Host "Found $($repoUsers.output.Count) users in repository: $orgAndRepoName"
    foreach ($user in $repoUsers.output) {
        $userLogin = $user.login

        if ($allowedUsers -contains $userLogin -and $user.role_name -eq "admin") {
            Write-Warning "User has direct access to $orgAndRepoName, but is an owner or AVM core team member and has admin access. They are likely JIT elevated, so skipping the error: $($userLogin)"
        } else {
            Write-Warning "User has direct access to $orgAndRepoName, but AVM repos cannot have direct user access outside of JIT, removing access now: $($userLogin) - role: $($user.role_name)"
            $issueLog = Invoke-CollaboratorRemoval -orgAndRepoName $orgAndRepoName -userLogin $userLogin -planOnly $planOnly -issueLog $issueLog
        }
    }

    return $issueLog
}

# Helper for `Remove-DirectCollaborators` that applies plan-only handling.
function Invoke-CollaboratorRemoval {
    param(
        [string]$orgAndRepoName,
        [string]$userLogin,
        [bool]$planOnly,
        [array]$issueLog
    )

    if ($planOnly) {
        Write-Host "Would run command: gh api 'repos/$orgAndRepoName/collaborators/$($userLogin)' -X DELETE"
        return $issueLog
    }

    $result = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "repos/$orgAndRepoName/collaborators/$($userLogin)", "-X", "DELETE")
                OutputLog = "remove-user.json"
            }
        ) `
        -printOutputOnError

    if (!$result.success) {
        Write-Warning "Failed to remove user: $($userLogin) from repository: $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "user-removal-failed" -message "Failed to remove user $($userLogin) from repository $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    return $issueLog
}

# Removes any team that has access to the repo but is not in the configured
# `$githubTeams` map. Teams in `$extraTeamsToIgnore` (e.g. `security`) are
# left in place.
function Remove-UnmanagedRepositoryTeams {
    param(
        [string]$orgName,
        [string]$orgAndRepoName,
        [hashtable]$githubTeams,
        [string[]]$extraTeamsToIgnore,
        [bool]$planOnly,
        [array]$issueLog
    )

    $repoTeams = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "repos/$orgAndRepoName/teams", "--paginate")
                OutputLog = "repo-teams.json"
            }
        ) `
        -returnOutputParsedFromJson

    if (!$repoTeams.success) {
        Write-Warning "Failed to get repository teams for: $orgAndRepoName. Skipping."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "repo-teams-fetch-failed" -message "Failed to fetch repository teams for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    Write-Host "Found $($repoTeams.output.Count) teams in repository: $orgAndRepoName"
    foreach ($team in $repoTeams.output) {
        $teamName = $team.name
        if ($extraTeamsToIgnore -contains $teamName) {
            Write-Host "Skipping team: $($teamName) as it is in the ignore list."
            continue
        }
        if (!$githubTeams.ContainsKey($teamName)) {
            Write-Warning "Team exists in repository but not in config, will be removed: $($teamName)"
            $teamSlug = $team.slug
            if ($planOnly) {
                Write-Host "Would run command: gh api 'orgs/$orgName/teams/$($teamSlug)/repos/$orgAndRepoName' -X DELETE"
            } else {
                $result = Invoke-GitHubCliWithRetry `
                    -commands @(
                        @{
                            Arguments = @("api", "orgs/$orgName/teams/$($teamSlug)/repos/$orgAndRepoName", "-X", "DELETE")
                            OutputLog = "remove-team.json"
                        }
                    ) `
                    -printOutputOnError

                if (!$result.success) {
                    Write-Warning "Failed to remove team: $($teamName) from repository: $orgAndRepoName. Exiting."
                    $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "team-removal-failed" -message "Failed to remove team $($teamName) from repository $orgAndRepoName." -data $null -issueLog $issueLog
                    exit 1
                }
            }
        }
    }

    return $issueLog
}
