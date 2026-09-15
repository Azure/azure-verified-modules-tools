function Assert-AvmBicepOwnerSnapshotCount {
    param([object] $Value, [string] $Label)

    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt 0) {
        throw [System.ArgumentException]::new("Malformed Bicep owner snapshot: $Label must be a nonnegative integer.")
    }
}

function Read-AvmBicepOwnerSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $snapshot = Read-AvmMetadataBackfillJson -Path $Path
    foreach ($field in @('CapturedAtUtc', 'QueryUrl', 'ReportedQueryMatches', 'RetrievedQueryMatches', 'PageCount', 'Teams')) {
        if (@($snapshot.Keys) -cnotcontains $field) {
            throw [System.ArgumentException]::new("Malformed Bicep owner snapshot: missing $field.")
        }
    }
    if ($snapshot.QueryUrl -cne 'https://github.com/orgs/Azure/teams?query=owners-bicep' -or $snapshot.Teams -isnot [array]) {
        throw [System.ArgumentException]::new('Malformed Bicep owner snapshot: expected the Azure owners-bicep query and a Teams array.')
    }
    foreach ($field in @('ReportedQueryMatches', 'RetrievedQueryMatches', 'PageCount')) {
        Assert-AvmBicepOwnerSnapshotCount -Value $snapshot[$field] -Label $field
    }
    if ($snapshot.PageCount -lt 1 -or $snapshot.Teams.Count -lt 1 -or
        $snapshot.ReportedQueryMatches -ne $snapshot.RetrievedQueryMatches -or
        $snapshot.RetrievedQueryMatches -ne $snapshot.Teams.Count) {
        throw [System.ArgumentException]::new('Incomplete Bicep owner snapshot: ReportedQueryMatches, RetrievedQueryMatches, and Teams count must agree, with at least one team and page.')
    }

    $slugs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $teams = [System.Collections.Generic.List[object]]::new()
    foreach ($team in $snapshot.Teams) {
        if ($team -isnot [System.Collections.IDictionary] -or $team['slug'] -isnot [string] -or
            $team['slug'] -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
            throw [System.ArgumentException]::new('Malformed Bicep owner snapshot: each team requires a canonical GitHub slug.')
        }
        $slug = $team.slug
        if (-not $slugs.Add($slug)) {
            throw [System.ArgumentException]::new("Malformed Bicep owner snapshot: duplicate team '$slug'.")
        }
        if ($team['url'] -cne "https://github.com/orgs/Azure/teams/$slug" -or
            $team['members'] -isnot [System.Collections.IDictionary]) {
            throw [System.ArgumentException]::new("Malformed Bicep owner snapshot: '$slug' requires its Azure team URL and members object.")
        }
        $members = $team.members
        Assert-AvmBicepOwnerSnapshotCount -Value $members['totalCount'] -Label "$slug members.totalCount"
        if ($members['edges'] -isnot [array] -or $members['pageInfo'] -isnot [System.Collections.IDictionary] -or
            $members.pageInfo['hasNextPage'] -isnot [bool] -or $members.pageInfo.hasNextPage -or
            $members.totalCount -ne $members.edges.Count) {
            throw [System.ArgumentException]::new("Incomplete Bicep owner snapshot: '$slug' requires members.totalCount equal to edges count and hasNextPage false.")
        }
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $handles = [System.Collections.Generic.List[string]]::new()
        foreach ($edge in $members.edges) {
            if ($edge -isnot [System.Collections.IDictionary] -or $edge['role'] -isnot [string] -or
                $edge['role'] -cnotin @('MEMBER', 'MAINTAINER') -or
                $edge['node'] -isnot [System.Collections.IDictionary] -or $edge.node['login'] -isnot [string]) {
                throw [System.ArgumentException]::new("Malformed Bicep owner snapshot: '$slug' requires MEMBER/MAINTAINER edges with node.login.")
            }
            $login = $edge.node.login
            if ($login -cnotmatch '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$' -or $login.Length -gt 39 -or -not $seen.Add($login)) {
                throw [System.ArgumentException]::new("Malformed Bicep owner snapshot: '$slug' contains an invalid or duplicate member login.")
            }
            $handles.Add($login)
        }
        $teams.Add([pscustomobject]@{ Slug = $slug; GitHubHandles = $handles.ToArray() })
    }
    return [pscustomobject]@{
        TeamCount = $teams.Count
        PageCount = $snapshot.PageCount
        Teams     = $teams.ToArray()
    }
}

function ConvertTo-AvmBicepOwnerTeamSlug {
    param([AllowNull()][string] $Reference)

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        return
    }
    $value = $Reference.Trim()
    if ($value -match '^(?:@?(?<org>[A-Za-z0-9-]+)/|https://github\.com/orgs/(?<org>[A-Za-z0-9-]+)/teams/)(?<slug>[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)$') {
        if ($Matches.org -ine 'Azure') {
            throw [System.ArgumentException]::new('Bicep owner snapshot team references must belong to Azure.')
        }
        return $Matches.slug.ToLowerInvariant()
    }
    if ($value -match '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$') {
        return $value.ToLowerInvariant()
    }
    throw [System.ArgumentException]::new('ModuleOwnersGHTeam must identify an exact GitHub team slug, Azure team handle, or Azure team URL.')
}

function Get-AvmBicepOwnerSnapshotMapping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Snapshot,
        [Parameter(Mandatory)][object[]] $Module,
        [Parameter(Mandatory)][System.Collections.IDictionary] $LegacyRecordByPath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $roots = @($Module | Where-Object { $null -eq $_.ParentPath })
    $legacy = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $normalized = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $issues = [System.Collections.Generic.List[object]]::new()
    $unmatched = [System.Collections.Generic.List[string]]::new()
    $ambiguous = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $proposals = [System.Collections.Generic.List[object]]::new()
    $byPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $allSlugs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($team in $Snapshot.Teams) {
        $null = $allSlugs.Add($team.Slug)
    }
    foreach ($root in $roots) {
        $references = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($record in @($LegacyRecordByPath[$root.Path])) {
            try {
                $slug = ConvertTo-AvmBicepOwnerTeamSlug -Reference $record['ModuleOwnersGHTeam']
                if ($slug) {
                    $null = $references.Add($slug)
                }
            }
            catch [System.ArgumentException] {
                $issues.Add([pscustomobject]@{ Code = 'AVM_OWNER_TEAM_REFERENCE'; Message = "$($root.Path): $($_.Exception.Message)" })
            }
        }
        $legacy.Add($root.Path, $references)
        $segments = $root.Path.Split('/')
        $normalized.Add($root.Path, ('avm-' + $segments[1] + '-' +
                $segments[2].Replace('-', '').ToLowerInvariant() + '-' +
                $segments[3].Replace('-', '').ToLowerInvariant() + '-module-owners-bicep'))
    }
    foreach ($team in $Snapshot.Teams) {
        $candidates = @($roots | Where-Object { $legacy[$_.Path].Contains($team.Slug) })
        $method = 'legacy-team'
        if ($candidates.Count -eq 0) {
            $candidates = @($roots | Where-Object { $normalized[$_.Path] -ceq $team.Slug })
            $method = 'normalized-path'
        }
        if ($candidates.Count -eq 0) {
            $unmatched.Add($team.Slug)
            $issues.Add([pscustomobject]@{
                    Code    = 'AVM_OWNER_TEAM_UNMATCHED'
                    Message = "Snapshot team '$($team.Slug)' has no discovered root mapping; reconcile the legacy ModuleOwnersGHTeam mapping before preparing seeds."
                })
        }
        elseif ($candidates.Count -gt 1) {
            $null = $ambiguous.Add($team.Slug)
            $issues.Add([pscustomobject]@{
                    Code    = 'AVM_OWNER_TEAM_AMBIGUOUS'
                    Message = "Snapshot team '$($team.Slug)' ambiguously matches roots: $($candidates.Path -join ', '). Supply an exact legacy ModuleOwnersGHTeam mapping."
                })
        }
        else {
            $proposals.Add([pscustomobject]@{ Path = $candidates[0].Path; Team = $team; Method = $method })
        }
    }
    foreach ($root in $roots) {
        $claims = @($proposals | Where-Object { $_.Path -ceq $root.Path })
        if ($claims.Count -gt 1) {
            foreach ($claim in $claims) {
                $null = $ambiguous.Add($claim.Team.Slug)
            }
            $issues.Add([pscustomobject]@{
                    Code    = 'AVM_OWNER_TEAM_AMBIGUOUS'
                    Message = "Root '$($root.Path)' matches more than one deleted team: $($claims.Team.Slug -join ', '). Resolve the ambiguous mapping before preparing seeds."
                })
        }
        elseif ($claims.Count -eq 1) {
            $byPath.Add($root.Path, [pscustomobject]@{
                    Team                 = $claims[0].Team
                    Method               = $claims[0].Method
                    UnmatchedLegacyTeams = @($legacy[$root.Path] | Where-Object { -not $allSlugs.Contains($_) } | Sort-Object -CaseSensitive)
                })
        }
        else {
            foreach ($slug in $legacy[$root.Path]) {
                if ($slug.EndsWith('-module-owners-bicep', [System.StringComparison]::Ordinal) -and -not $allSlugs.Contains($slug)) {
                    $issues.Add([pscustomobject]@{
                            Code    = 'AVM_OWNER_TEAM_UNMATCHED'
                            Message = "Root '$($root.Path)' references '$slug', which is absent from the snapshot, and has no unambiguous fallback mapping."
                        })
                }
            }
        }
    }
    return [pscustomobject]@{
        ByPath  = $byPath
        Slugs   = $allSlugs
        Summary = [pscustomobject]@{
            TeamCount       = $Snapshot.TeamCount
            MappedTeamCount = $byPath.Count
            UnmatchedTeams  = $unmatched.ToArray()
            AmbiguousTeams  = @($ambiguous | Sort-Object -CaseSensitive)
            Issues          = $issues.ToArray()
        }
    }
}
