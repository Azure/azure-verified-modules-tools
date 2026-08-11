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
    param(
        [object]$claimOverrides
    )

    return [pscustomobject]@{
        name = "default"
        order = -100
        repositories = @("*")
        teams = @(
            [pscustomobject]@{ name = "test-contributors"; permission = "push" },
            [pscustomobject]@{ name = "test-readers"; permission = "pull" }
        )
        workloadIdentityFederationSubjectClaimOverrides = $claimOverrides
    }
}

$defaultRef = "Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main"
$groupRef = "Azure/example/.github/workflows/terraform-module.yml@refs/heads/release"

$defaultOnlyConfig = [pscustomobject]@{
    repositoryGroups = @(
        (New-DefaultGroup -claimOverrides ([pscustomobject]@{ jobWorkflowRef = $defaultRef }))
    )
}
$defaultOnlySettings = Resolve-RepositorySettings -repositoryConfig $defaultOnlyConfig -repoId "unlisted-repository"
Assert-Equal $defaultRef $defaultOnlySettings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"] "Default group OIDC subject was not applied."
Assert-Equal 2 $defaultOnlySettings.Teams.Count "Default group teams were not resolved."

$overrideConfig = [pscustomobject]@{
    repositoryGroups = @(
        (New-DefaultGroup -claimOverrides ([pscustomobject]@{ jobWorkflowRef = $defaultRef })),
        [pscustomobject]@{
            name = "override"
            order = 10
            repositories = @("overridden-repository")
            workloadIdentityFederationSubjectClaimOverrides = [pscustomobject]@{
                jobWorkflowRef = $groupRef
            }
        }
    )
}
$overrideSettings = Resolve-RepositorySettings -repositoryConfig $overrideConfig -repoId "overridden-repository"
Assert-Equal $groupRef $overrideSettings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"] "Repository-group OIDC subject override did not win."

$unmatchedSettings = Resolve-RepositorySettings -repositoryConfig $overrideConfig -repoId "other-repository"
Assert-Equal $defaultRef $unmatchedSettings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"] "A non-matching group leaked its OIDC subject override."

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
foreach ($repository in $configuredRepositories) {
    $actualSettings = Resolve-RepositorySettings -repositoryConfig $actualConfig -repoId $repository
    Assert-Equal $defaultRef $actualSettings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"] "The checked-in OIDC subject is incorrect for '$repository'."
}

Assert-Throws -MessagePattern "Repository group 'default' sets unsupported*" -Action {
    $invalidKeyConfig = [pscustomobject]@{
        repositoryGroups = @(
            (New-DefaultGroup -claimOverrides ([pscustomobject]@{ unsupported = "value" }))
        )
    }
    Resolve-RepositorySettings -repositoryConfig $invalidKeyConfig -repoId "repository"
}

Assert-Throws -MessagePattern "workloadIdentityFederationSubjectClaimOverrides.jobWorkflowRef must use the form*" -Action {
    $invalidRefConfig = [pscustomobject]@{
        repositoryGroups = @(
            (New-DefaultGroup -claimOverrides ([pscustomobject]@{ jobWorkflowRef = "Azure/example/.github/workflows/terraform-module.yml@main" }))
        )
    }
    Resolve-RepositorySettings -repositoryConfig $invalidRefConfig -repoId "repository"
}

Assert-Throws -MessagePattern "workloadIdentityFederationSubjectClaimOverrides.jobWorkflowRef must use the form*" -Action {
    $invalidWorkflowConfig = [pscustomobject]@{
        repositoryGroups = @(
            (New-DefaultGroup -claimOverrides ([pscustomobject]@{ jobWorkflowRef = "not-a-workflow@refs/heads/main" }))
        )
    }
    Resolve-RepositorySettings -repositoryConfig $invalidWorkflowConfig -repoId "repository"
}

$shaRef = "Azure/example/.github/workflows/terraform-module.yaml@0123456789abcdef0123456789abcdef01234567"
$shaConfig = [pscustomobject]@{
    repositoryGroups = @(
        (New-DefaultGroup -claimOverrides ([pscustomobject]@{ jobWorkflowRef = $shaRef }))
    )
}
$shaSettings = Resolve-RepositorySettings -repositoryConfig $shaConfig -repoId "repository"
Assert-Equal $shaRef $shaSettings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"] "A valid workflow SHA ref was rejected."

Write-Host "Repository configuration tests passed."
