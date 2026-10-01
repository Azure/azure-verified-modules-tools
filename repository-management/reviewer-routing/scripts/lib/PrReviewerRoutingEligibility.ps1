#Requires -Version 7.4

function Get-AvmPrReviewerRoutingReviewState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [object] $PullRequest)

    $requestedUsers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $requestedTeams = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $reviewedUsers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($request in $PullRequest.reviewRequests) {
        if ($request.PSObject.Properties['login'] -and $request.login) {
            $null = $requestedUsers.Add([string]$request.login)
        }
        elseif ($request.PSObject.Properties['slug'] -and $request.slug) {
            $null = $requestedTeams.Add(([string]$request.slug -split '/')[-1])
        }
        elseif ($request.PSObject.Properties['name'] -and $request.name) {
            $null = $requestedTeams.Add(([string]$request.name -split '/')[-1])
        }
    }
    foreach ($review in $PullRequest.reviews) {
        if ($review.PSObject.Properties['state'] -and $review.state -ieq 'PENDING') {
            continue
        }
        if ($review.PSObject.Properties['author'] -and $review.author -and $review.author.PSObject.Properties['login']) {
            $null = $reviewedUsers.Add([string]$review.author.login)
        }
    }
    return @{
        Author = if ($PullRequest.PSObject.Properties['author'] -and $PullRequest.author -and $PullRequest.author.PSObject.Properties['login']) {
            [string]$PullRequest.author.login
        } else { $null }
        RequestedUsers = $requestedUsers
        RequestedTeams = $requestedTeams
        ReviewedUsers = $reviewedUsers
    }
}

function Get-AvmPrReviewerRoutingEligibility {
    <#
    .SYNOPSIS
    Checks a user's or team's repository write access without changing it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Handle,
        [Parameter(Mandatory)] [ValidateSet('user', 'team')] [string] $Type,
        [hashtable] $Cache = @{}
    )

    $key = "$Repository`:$Type`:$Handle"
    if ($Cache.ContainsKey($key)) {
        return $Cache[$key]
    }
    $endpoint = "repos/$Repository/collaborators/$Handle/permission"
    $accept = 'application/vnd.github+json'
    if ($Type -ceq 'team') {
        $parts = $Handle -split '/'
        if ($parts.Count -ne 2 -or $parts[0] -ine ($Repository -split '/')[0]) {
            $Cache[$key] = @{ Eligible = $false; Reason = 'the team does not belong to the repository organization' }
            return $Cache[$key]
        }
        $endpoint = "orgs/$($parts[0])/teams/$($parts[1])/repos/$Repository"
        $accept = 'application/vnd.github.v3.repository+json'
    }
    try {
        $access = Invoke-RepositoryGitHub -AsJson -Arguments @(
            'api', '--hostname', 'github.com', '--method', 'GET',
            '--header', "Accept: $accept", '--header', 'X-GitHub-Api-Version: 2022-11-28', $endpoint
        )
    }
    catch [System.InvalidOperationException] {
        if ($_.Exception.Message -notmatch '\(HTTP 404\)') {
            throw
        }
        $Cache[$key] = @{ Eligible = $false; Reason = 'the owner is not found or has no repository access' }
        return $Cache[$key]
    }

    if ($Type -ceq 'user') {
        if ($null -eq $access -or -not $access.PSObject.Properties['permission'] -or
            -not $access.PSObject.Properties['user'] -or $null -eq $access.user -or
            -not $access.user.PSObject.Properties['login'] -or $access.user.login -ine $Handle -or
            $access.permission -cnotin @('none', 'read', 'triage', 'triage_plus', 'write', 'maintain', 'admin')) {
            throw [System.IO.InvalidDataException]::new("GitHub returned invalid reviewer permissions for [$Handle] in [$Repository].")
        }
        $eligible = $access.permission -cin @('write', 'maintain', 'admin')
    }
    else {
        if ($null -eq $access -or -not $access.PSObject.Properties['full_name'] -or $access.full_name -ine $Repository -or
            -not $access.PSObject.Properties['permissions'] -or $null -eq $access.permissions -or
            -not $access.permissions.PSObject.Properties['push'] -or $access.permissions.push -isnot [bool]) {
            throw [System.IO.InvalidDataException]::new("GitHub returned invalid reviewer permissions for team [$Handle] in [$Repository].")
        }
        $eligible = $access.permissions.push
    }
    $Cache[$key] = @{
        Eligible = [bool]$eligible
        Reason = if ($eligible) { $null } else { 'the owner does not have repository write access' }
    }
    return $Cache[$key]
}

function Write-AvmPrReviewerRoutingWarning {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Message)

    Write-Warning $Message
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $escaped = $Message.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
        Write-Information "::warning title=Module reviewer routing::$escaped" -InformationAction Continue
    }
}

function Assert-AvmPrReviewerRoutingApplied {
    <#
    .SYNOPSIS
    Reads the request back so a successful CLI exit cannot hide a missing reviewer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $PullRequest,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [hashtable] $Routing
    )

    $current = @(Get-AvmPrReviewerRoutingCandidates -Repository $Repository -PullRequestUrl $PullRequest.url)
    if ($current.Count -ne 1 -or $current[0].number -ne $PullRequest.number -or $current[0].url -ine $PullRequest.url) {
        throw [System.IO.InvalidDataException]::new("Cannot verify routing on pull request [$($PullRequest.url)].")
    }
    $state = Get-AvmPrReviewerRoutingReviewState -PullRequest $current[0]
    $missingReviewers = @($Routing.NewReviewers | Where-Object {
            if ($Routing.ReviewerTypes[$_] -ceq 'team') {
                -not $state.RequestedTeams.Contains(($_ -split '/')[-1])
            }
            else {
                -not $state.RequestedUsers.Contains($_) -and -not $state.ReviewedUsers.Contains($_)
            }
        })
    $currentLabels = @($current[0].labels | ForEach-Object { $_.name })
    $missingLabels = @($Routing.NewLabels | Where-Object { $currentLabels -notcontains $_ })
    if ($missingReviewers.Count -gt 0 -or $missingLabels.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "GitHub did not apply routing on pull request [$($PullRequest.url)]. " +
            "Missing reviewers: [$(Format-AvmRunSummaryList -Values $missingReviewers)]. " +
            "Missing labels: [$(Format-AvmRunSummaryList -Values $missingLabels)].")
    }
}
