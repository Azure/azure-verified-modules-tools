Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/RepositoryConfig.ps1")

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$MessagePattern
    )

    $thrown = $false
    try {
        & $Action
    } catch {
        $thrown = $true
        if ($_.Exception.Message -notlike $MessagePattern) {
            throw "Expected error matching '$MessagePattern', got '$($_.Exception.Message)'."
        }
    }

    if (-not $thrown) {
        throw "Expected an error matching '$MessagePattern'."
    }
}

function New-DefaultGroup {
    return [pscustomobject]@{
        name = "default"
        order = -100
        repositories = @("*")
        teams = @(
            [pscustomobject]@{ name = "test-contributors"; permission = "push" },
            [pscustomobject]@{ name = "test-readers"; permission = "pull" }
        )
    }
}

$defaultOnlyConfig = [pscustomobject]@{
    repositoryGroups = @(
        (New-DefaultGroup)
    )
}
$defaultOnlySettings = Resolve-RepositorySettings -repositoryConfig $defaultOnlyConfig -repoId "unlisted-repository"
Assert-Equal 2 $defaultOnlySettings.Teams.Count "Default group teams were not resolved."
Assert-Equal 0 $defaultOnlySettings.PullRequestBypassTeams.Count "Unlisted repositories must not have a team bypass."

$overrideConfig = [pscustomobject]@{
    repositoryGroups = @(
        (New-DefaultGroup),
        [pscustomobject]@{
            name = "override"
            order = 10
            repositories = @("overridden-repository")
            pullRequestBypassTeams = @("test-contributors")
        },
        [pscustomobject]@{
            name = "also-overridden"
            order = 5
            repositories = @("overridden-repository")
            teams = @([pscustomobject]@{ name = "test-owners"; repositoryPermission = "push" })
            pullRequestBypassTeams = @("test-contributors", "test-owners")
        }
    )
}
$overrideSettings = Resolve-RepositorySettings -repositoryConfig $overrideConfig -repoId "overridden-repository"
Assert-Equal "test-contributors,test-owners" ($overrideSettings.PullRequestBypassTeams -join ",") "Matching group bypass teams were not combined without duplicates."

$unmatchedSettings = Resolve-RepositorySettings -repositoryConfig $overrideConfig -repoId "other-repository"
Assert-Equal 0 $unmatchedSettings.PullRequestBypassTeams.Count "A non-matching group leaked its bypass teams."

$actualConfigPath = [System.IO.Path]::Combine(
    $PSScriptRoot,
    "..",
    "..",
    "repository-config",
    "config.json"
)
$actualConfig = Get-Content -Path $actualConfigPath -Raw | ConvertFrom-Json
$configuredRepositories = @(
    $actualConfig.repositoryGroups |
        ForEach-Object { $_.repositories } |
        Where-Object { $_ -ne "*" } |
        Select-Object -Unique
)
$configuredRepositories += "unlisted-repository"
$expectedBypassTeams = "azure-verified-modules-engineering-owners"
foreach ($repository in $configuredRepositories) {
    $actualSettings = Resolve-RepositorySettings -repositoryConfig $actualConfig -repoId $repository
    Assert-Equal $expectedBypassTeams ($actualSettings.PullRequestBypassTeams -join ",") "Unexpected pull-request bypass teams for '$repository'."
}

Assert-Throws -MessagePattern "*pullRequestBypassTeams must be an array*" -Action {
    $invalidConfig = [pscustomobject]@{
        repositoryGroups = @(
            (New-DefaultGroup),
            [pscustomobject]@{
                name = "invalid"
                repositories = @("repository")
                pullRequestBypassTeams = "test-contributors"
            }
        )
    }
    Resolve-RepositorySettings -repositoryConfig $invalidConfig -repoId "repository"
}

Assert-Throws -MessagePattern "*not a configured team slug*" -Action {
    $invalidConfig = [pscustomobject]@{
        repositoryGroups = @(
            (New-DefaultGroup),
            [pscustomobject]@{
                name = "invalid"
                repositories = @("repository")
                pullRequestBypassTeams = @("unconfigured-team")
            }
        )
    }
    Resolve-RepositorySettings -repositoryConfig $invalidConfig -repoId "repository"
}

Write-Host "Repository configuration tests passed."
