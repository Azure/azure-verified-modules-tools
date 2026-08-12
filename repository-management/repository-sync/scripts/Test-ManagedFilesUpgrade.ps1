Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/ManagedFilesUpgrade.ps1")

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Description
    )

    if ($Actual -ne $Expected) {
        throw "Expected $Description to be '$Expected', got '$Actual'."
    }
}

function New-TestRepoRoot {
    param(
        [string]$pinnedVersion
    )

    $repoRoot = Join-Path ([System.IO.Path]::GetTempPath()) "avm-upgrade-test-$([guid]::NewGuid().ToString('n'))"
    $null = New-Item -ItemType Directory -Path $repoRoot -Force

    if ($pinnedVersion) {
        $null = New-Item -ItemType Directory -Path (Join-Path $repoRoot ".avm") -Force
        $pin = @{
            version    = $pinnedVersion
            repo       = "Azure/azure-verified-modules-managed-files"
            commit     = "0000000000000000000000000000000000000000"
            commitDate = "2026-08-11T21:52:43Z"
            updatedAt  = "2026-08-12T11:08:52Z"
        } | ConvertTo-Json
        Set-Content -LiteralPath (Join-Path $repoRoot ".avm/managed-files-version.json") -Value $pin -NoNewline
    }

    return $repoRoot
}

function New-TestPullRequest {
    param(
        [int]$number,
        [double]$updatedDaysAgo = 0,
        [bool]$isDraft = $false,
        [bool]$isBot = $false
    )

    return @{
        number    = $number
        title     = "Test pull request $number"
        updatedAt = (Get-Date).ToUniversalTime().AddDays(-$updatedDaysAgo).ToString("yyyy-MM-ddTHH:mm:ssZ")
        isDraft   = $isDraft
        author    = @{ login = "someone"; is_bot = $isBot }
    }
}

$script:tags = @()
$script:pullRequests = @()
$script:gitExitCode = 0
$script:ghExitCode = 0

function git {
    $global:LASTEXITCODE = $script:gitExitCode
    if ($script:gitExitCode -ne 0) { return @() }

    return @(
        foreach ($tag in $script:tags) {
            "0000000000000000000000000000000000000000`trefs/tags/$tag"
        }
    )
}

function gh {
    $global:LASTEXITCODE = $script:ghExitCode
    if ($script:ghExitCode -ne 0) { return @() }

    return (ConvertTo-Json -InputObject @($script:pullRequests) -Depth 5)
}

$repoRoots = @()

try {
    # Pin reading.
    $pinnedRoot = New-TestRepoRoot -pinnedVersion "1.2.3"
    $repoRoots += $pinnedRoot
    Assert-Equal -Actual (Get-AvmManagedFilesPinnedVersion -repoRoot $pinnedRoot) -Expected ([semver]"1.2.3") -Description "pinned version"

    $unpinnedRoot = New-TestRepoRoot
    $repoRoots += $unpinnedRoot
    Assert-Equal -Actual (Get-AvmManagedFilesPinnedVersion -repoRoot $unpinnedRoot) -Expected $null -Description "missing pin"

    # Latest version discovery ignores non-semver tags and unsorted input.
    $script:tags = @("v0.9.0", "latest", "v2.0.0", "v10.1.0", "v2.4.1")
    Assert-Equal -Actual (Get-AvmManagedFilesLatestVersion) -Expected ([semver]"10.1.0") -Description "latest tag"

    $script:tags = @("latest", "not-a-version")
    Assert-Equal -Actual (Get-AvmManagedFilesLatestVersion) -Expected $null -Description "latest tag when none are semver"

    # Blocking pull request filters.
    $script:tags = @("v1.3.0")
    $script:pullRequests = @(
        (New-TestPullRequest -number 1 -updatedDaysAgo 1)
        (New-TestPullRequest -number 2 -updatedDaysAgo 1 -isDraft $true)
        (New-TestPullRequest -number 3 -updatedDaysAgo 1 -isBot $true)
        (New-TestPullRequest -number 4 -updatedDaysAgo 20)
        (New-TestPullRequest -number 5 -updatedDaysAgo 13.9)
        (New-TestPullRequest -number 6 -updatedDaysAgo 14.1)
    )

    $blocking = @(Get-AvmBlockingPullRequest -orgAndRepoName "Azure/test-repo")
    Assert-Equal -Actual $blocking.Count -Expected 2 -Description "blocking pull request count"
    Assert-Equal -Actual (($blocking | ForEach-Object { $_.number }) -join ",") -Expected "1,5" -Description "blocking pull request numbers"

    # Minor upgrade is blocked by an active human pull request.
    $decision = Resolve-AvmManagedFilesUpgradeDecision -orgAndRepoName "Azure/test-repo" -repoRoot $pinnedRoot
    Assert-Equal -Actual $decision.Upgrade -Expected $false -Description "blocked minor upgrade"
    Assert-Equal -Actual $decision.BlockingPullRequestCount -Expected 2 -Description "blocked minor upgrade pull request count"

    # Minor upgrade proceeds once only bots and stale pull requests remain.
    $script:pullRequests = @(
        (New-TestPullRequest -number 3 -updatedDaysAgo 1 -isBot $true)
        (New-TestPullRequest -number 4 -updatedDaysAgo 20)
    )
    $decision = Resolve-AvmManagedFilesUpgradeDecision -orgAndRepoName "Azure/test-repo" -repoRoot $pinnedRoot
    Assert-Equal -Actual $decision.Upgrade -Expected $true -Description "unblocked minor upgrade"

    # A major release upgrades even when human pull requests are active.
    $script:tags = @("v2.0.0")
    $script:pullRequests = @((New-TestPullRequest -number 1 -updatedDaysAgo 1))
    $decision = Resolve-AvmManagedFilesUpgradeDecision -orgAndRepoName "Azure/test-repo" -repoRoot $pinnedRoot
    Assert-Equal -Actual $decision.Upgrade -Expected $true -Description "major upgrade despite active pull requests"
    Assert-Equal -Actual $decision.BlockingPullRequestCount -Expected 0 -Description "major upgrade skips the pull request query"

    # An up to date pin never upgrades.
    $script:tags = @("v1.2.3")
    $decision = Resolve-AvmManagedFilesUpgradeDecision -orgAndRepoName "Azure/test-repo" -repoRoot $pinnedRoot
    Assert-Equal -Actual $decision.Upgrade -Expected $false -Description "current pin upgrade"

    # An unpinned repository bootstraps through the sync itself, not the upgrade switch.
    $decision = Resolve-AvmManagedFilesUpgradeDecision -orgAndRepoName "Azure/test-repo" -repoRoot $unpinnedRoot
    Assert-Equal -Actual $decision.Upgrade -Expected $false -Description "unpinned upgrade"
    Assert-Equal -Actual $decision.Reason -Expected "no version pin recorded; the sync will adopt the newest release and stamp it" -Description "unpinned reason"

    # Lookup failures stay on the pinned version rather than failing the sync.
    $script:tags = @("v2.0.0")
    $script:gitExitCode = 1
    $decision = Resolve-AvmManagedFilesUpgradeDecision -orgAndRepoName "Azure/test-repo" -repoRoot $pinnedRoot
    Assert-Equal -Actual $decision.Upgrade -Expected $false -Description "tag lookup failure upgrade"

    $script:gitExitCode = 0
    $script:tags = @("v1.3.0")
    $script:ghExitCode = 1
    $decision = Resolve-AvmManagedFilesUpgradeDecision -orgAndRepoName "Azure/test-repo" -repoRoot $pinnedRoot
    Assert-Equal -Actual $decision.Upgrade -Expected $false -Description "pull request lookup failure upgrade"
} finally {
    $script:ghExitCode = 0
    $script:gitExitCode = 0
    Remove-Item Function:git -ErrorAction SilentlyContinue
    Remove-Item Function:gh -ErrorAction SilentlyContinue
    foreach ($repoRoot in $repoRoots) {
        Remove-Item -LiteralPath $repoRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Managed files upgrade decision tests passed."
