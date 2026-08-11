# Resolves the per-repository view of `repository-config/config.json`:
# teams, code-owners teams, topics, and workload identity federation claim
# overrides.
#
# Managed-file group selection is deliberately NOT resolved here. Avm.Authoring's
# Sync-AvmManagedFile.ps1 owns that resolution end to end, so there is only one
# implementation of the ordering rules to keep correct.
#
# Returns a hashtable so the orchestrator can pull fields by name rather than
# unpacking positional return values.

function Resolve-RepositorySettings {
    param(
        [object]$repositoryConfig,
        [string]$repoId
    )

    # A group whose `repositories` contains "*" matches every repository. The
    # `default` group uses this to carry organisation-wide settings, replacing
    # the former root-level blocks and the implicit "all" pseudo-group.
    $repositoryGroups = @(
        $repositoryConfig.repositoryGroups |
            Where-Object { $_.repositories -contains '*' -or $_.repositories -contains $repoId }
    )

    $repositoryGroupNames = @($repositoryGroups | ForEach-Object { $_.name })

    # Teams are declared inline on the group they apply to. De-duplicate by
    # name so a team named by more than one matching group is only requested
    # once.
    $teams = @()
    $seenTeamNames = @{}
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains 'teams' -and $repositoryGroup.teams) {
            foreach ($team in @($repositoryGroup.teams)) {
                if ($seenTeamNames.ContainsKey($team.name)) { continue }
                $seenTeamNames[$team.name] = $true
                $teams += $team
            }
        }
    }

    # Collect the CODEOWNERS default teams from every repository group that
    # contains this repo. These teams become required reviewers for all files
    # in the repo (e.g. tier 1 modules require review from the engineering
    # owners team).
    $codeOwnersDefaultTeams = @()
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains 'codeOwnersTeams' -and $repositoryGroup.codeOwnersTeams) {
            $codeOwnersDefaultTeams += $repositoryGroup.codeOwnersTeams
        }
    }
    $codeOwnersDefaultTeams = @($codeOwnersDefaultTeams | Select-Object -Unique)

    # The teams that protect the CODEOWNERS file itself. The `default` group
    # sets these for every repository; a group may add more.
    $codeOwnersFileProtectionTeams = @()
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains 'codeOwnersFileProtectionTeams' -and $repositoryGroup.codeOwnersFileProtectionTeams) {
            $codeOwnersFileProtectionTeams += $repositoryGroup.codeOwnersFileProtectionTeams
        }
    }
    $codeOwnersFileProtectionTeams = @($codeOwnersFileProtectionTeams | Select-Object -Unique)

    # Collect repository topics from every matching group. The result is the
    # authoritative topic list for the repository, so any topic set on the repo
    # that is not in this list will be removed by Terraform.
    $repositoryTopics = @()
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains 'topics' -and $repositoryGroup.topics) {
            $repositoryTopics += $repositoryGroup.topics
        }
    }
    $repositoryTopics = @($repositoryTopics | Select-Object -Unique)

    # Workload identity federation subject-claim overrides, merged per key
    # across every group containing the repo using the same (order,
    # declaration index) precedence as managed-file groups: higher order wins.
    # The `default` group declares a negative order so it always loses.
    $supportedClaimOverrides = @{
        jobWorkflowRef = "github_job_workflow_ref"
    }

    $claimOverrideEntries = @()
    $claimDeclarationIndex = 0
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains 'workloadIdentityFederationSubjectClaimOverrides' -and $repositoryGroup.workloadIdentityFederationSubjectClaimOverrides) {
            $order = 0
            if ($repositoryGroup.PSObject.Properties.Name -contains 'order' -and $null -ne $repositoryGroup.order) {
                $order = [int]$repositoryGroup.order
            }
            foreach ($claimOverride in $repositoryGroup.workloadIdentityFederationSubjectClaimOverrides.PSObject.Properties) {
                if (-not $supportedClaimOverrides.ContainsKey($claimOverride.Name)) {
                    throw "Repository group '$($repositoryGroup.name)' sets unsupported workloadIdentityFederationSubjectClaimOverrides key '$($claimOverride.Name)'. Supported keys: $($supportedClaimOverrides.Keys -join ', ')."
                }
                $claimOverrideEntries += [pscustomobject]@{
                    Claim = $claimOverride.Name
                    Value = $claimOverride.Value
                    Order = $order
                    Index = $claimDeclarationIndex
                }
            }
        }
        $claimDeclarationIndex++
    }

    $workloadIdentityFederationSubjectClaimOverrides = @{}
    foreach ($claimOverrideEntry in ($claimOverrideEntries | Sort-Object -Property Order, Index)) {
        $workloadIdentityFederationSubjectClaimOverrides[$claimOverrideEntry.Claim] = $claimOverrideEntry.Value
    }

    # A job_workflow_ref claim always carries a fully-qualified git ref
    # (refs/heads/..., refs/tags/...) or a full commit SHA, even though `uses:`
    # is normally written as `@main`. Fail here rather than at OIDC exchange.
    if ($workloadIdentityFederationSubjectClaimOverrides.ContainsKey("jobWorkflowRef")) {
        $jobWorkflowRefOverride = $workloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"]
        $jobWorkflowRefPattern = "^[^/\s@]+/[^/\s@]+/\.github/workflows/[^/\s@]+\.ya?ml@(?:refs/[^\s]+|[0-9a-fA-F]{40})$"
        if ($jobWorkflowRefOverride -notmatch $jobWorkflowRefPattern) {
            throw "workloadIdentityFederationSubjectClaimOverrides.jobWorkflowRef must use the form 'owner/repository/.github/workflows/workflow.yml@refs/heads/branch' (a tag ref or full commit SHA is also supported), but was '$jobWorkflowRefOverride'."
        }
    }

    return @{
        RepositoryGroups                                = $repositoryGroups
        RepositoryGroupNames                            = $repositoryGroupNames
        Teams                                           = $teams
        CodeOwnersDefaultTeams                          = $codeOwnersDefaultTeams
        CodeOwnersFileProtectionTeams                   = $codeOwnersFileProtectionTeams
        Topics                                          = $repositoryTopics
        WorkloadIdentityFederationSubjectClaimOverrides = $workloadIdentityFederationSubjectClaimOverrides
    }
}