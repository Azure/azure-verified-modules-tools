$script:AvmManagedFilesRepo = "Azure/azure-verified-modules-managed-files"
$script:AvmManagedFilesPinPath = ".avm/managed-files-version.json"
$script:AvmPullRequestStalenessDays = 14

function Get-AvmManagedFilesPinnedVersion {
    param(
        [string]$repoRoot
    )

    $pinPath = Join-Path $repoRoot $script:AvmManagedFilesPinPath
    if (-not (Test-Path -LiteralPath $pinPath)) {
        return $null
    }

    $pin = $null
    try {
        $pin = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Could not parse $pinPath : $($_.Exception.Message)"
        return $null
    }

    if (-not $pin -or ($pin.PSObject.Properties.Name -notcontains "version")) {
        return $null
    }

    $version = $null
    if (-not [semver]::TryParse([string]$pin.version, [ref]$version)) {
        Write-Warning "Could not parse '$($pin.version)' in $pinPath as a semantic version."
        return $null
    }

    return $version
}

function Get-AvmManagedFilesLatestVersion {
    param(
        [string]$managedFilesRepo = $script:AvmManagedFilesRepo
    )

    $remoteUrl = "https://github.com/$managedFilesRepo.git"
    $output = git ls-remote --tags --refs $remoteUrl
    if ($LASTEXITCODE -ne 0) { throw "git ls-remote exited $LASTEXITCODE for $remoteUrl" }

    $versions = @(
        foreach ($line in @($output)) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }

            $fields = ([string]$line).Trim() -split "\s+"
            if ($fields.Count -lt 2) { continue }

            $tag = $fields[1] -replace "^refs/tags/", "" -replace "^v", ""
            $candidate = $null
            if ([semver]::TryParse($tag, [ref]$candidate)) {
                $candidate
            }
        }
    )

    if ($versions.Count -eq 0) {
        return $null
    }

    return (@($versions | Sort-Object -Descending) | Select-Object -First 1)
}

function Get-AvmBlockingPullRequest {
    param(
        [string]$orgAndRepoName,
        [int]$stalenessDays = $script:AvmPullRequestStalenessDays
    )

    $listOutput = gh pr list `
        --repo $orgAndRepoName `
        --state open `
        --limit 100 `
        --json number,title,updatedAt,isDraft,author
    if ($LASTEXITCODE -ne 0) { throw "gh pr list exited $LASTEXITCODE for $orgAndRepoName" }

    $raw = (@($listOutput) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $pullRequests = @($raw | ConvertFrom-Json)
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$stalenessDays)

    return @(
        foreach ($pullRequest in $pullRequests) {
            if (-not $pullRequest) { continue }

            $properties = $pullRequest.PSObject.Properties.Name

            if (($properties -contains "isDraft") -and $pullRequest.isDraft) { continue }

            # Bot authors never block. This covers Dependabot and the AVM bot's own
            # pre-commit pull requests, neither of which a human is waiting on.
            if (($properties -contains "author") -and $pullRequest.author) {
                $author = $pullRequest.author
                if (($author.PSObject.Properties.Name -contains "is_bot") -and $author.is_bot) { continue }
            }

            if ($properties -notcontains "updatedAt") { continue }

            $updatedAt = $null
            try {
                $updatedAt = ([datetime]$pullRequest.updatedAt).ToUniversalTime()
            } catch {
                Write-Warning "Could not parse updatedAt '$($pullRequest.updatedAt)' on $orgAndRepoName; treating the pull request as blocking."
                $pullRequest
                continue
            }

            if ($updatedAt -lt $cutoff) { continue }

            $pullRequest
        }
    )
}

function Resolve-AvmManagedFilesUpgradeDecision {
    param(
        [string]$orgAndRepoName,
        [string]$repoRoot,
        [string]$managedFilesRepo = $script:AvmManagedFilesRepo,
        [int]$stalenessDays = $script:AvmPullRequestStalenessDays,
        [bool]$forceFileUpdate = $false
    )

    $decision = @{
        Upgrade                  = $false
        Reason                   = ""
        PinnedVersion            = $null
        LatestVersion            = $null
        BlockingPullRequestCount = 0
    }

    if ($forceFileUpdate) {
        $decision.Upgrade = $true
        $decision.Reason = "manual workflow dispatch requested a managed-file update; upgrading regardless of release delta or open pull requests"
        return $decision
    }

    $pinnedVersion = Get-AvmManagedFilesPinnedVersion -repoRoot $repoRoot
    $decision.PinnedVersion = $pinnedVersion
    if (-not $pinnedVersion) {
        $decision.Reason = "no version pin recorded; the sync will adopt the newest release and stamp it"
        return $decision
    }

    try {
        $decision.LatestVersion = Get-AvmManagedFilesLatestVersion -managedFilesRepo $managedFilesRepo
    } catch {
        $decision.Reason = "could not determine the newest release ($($_.Exception.Message)); staying on the pinned version $pinnedVersion"
        return $decision
    }

    $latestVersion = $decision.LatestVersion
    if (-not $latestVersion) {
        $decision.Reason = "$managedFilesRepo has no release tags; staying on the pinned version $pinnedVersion"
        return $decision
    }

    if ($latestVersion -le $pinnedVersion) {
        $decision.Reason = "pinned version $pinnedVersion is current"
        return $decision
    }

    if ($latestVersion.Major -gt $pinnedVersion.Major) {
        $decision.Upgrade = $true
        $decision.Reason = "major release $latestVersion supersedes the pinned version $pinnedVersion; upgrading regardless of open pull requests"
        return $decision
    }

    try {
        $blocking = @(Get-AvmBlockingPullRequest -orgAndRepoName $orgAndRepoName -stalenessDays $stalenessDays)
    } catch {
        $decision.Reason = "could not list open pull requests ($($_.Exception.Message)); staying on the pinned version $pinnedVersion"
        return $decision
    }

    $decision.BlockingPullRequestCount = $blocking.Count
    if ($blocking.Count -gt 0) {
        $numbers = ($blocking | ForEach-Object { "#$($_.number)" }) -join ", "
        $decision.Reason = "$latestVersion is available but $($blocking.Count) active pull request(s) would be disrupted ($numbers); staying on the pinned version $pinnedVersion"
        return $decision
    }

    $decision.Upgrade = $true
    $decision.Reason = "$latestVersion supersedes the pinned version $pinnedVersion and no active pull requests would be disrupted"
    return $decision
}
