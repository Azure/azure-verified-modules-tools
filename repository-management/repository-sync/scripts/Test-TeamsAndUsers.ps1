Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Join-Path $PSScriptRoot "lib") "TeamsAndUsers.ps1")

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

$script:repoUsers = @(
    [pscustomobject]@{ login = "primary-owner"; role_name = "admin" }
    [pscustomobject]@{ login = "secondary-owner"; role_name = "admin" }
    [pscustomobject]@{ login = "primary-owner"; role_name = "write" }
    [pscustomobject]@{ login = "outside-user"; role_name = "admin" }
)
$script:removedUsers = @()

function Invoke-GitHubCliWithRetry {
    param(
        [array]$commands,
        [switch]$returnOutputParsedFromJson
    )

    return @{
        success = $true
        output  = $script:repoUsers
    }
}

function Invoke-CollaboratorRemoval {
    param(
        [string]$orgAndRepoName,
        [string]$userLogin,
        [bool]$planOnly,
        [array]$issueLog
    )

    $script:removedUsers += $userLogin
    return $issueLog
}

$parameters = (Get-Command Remove-DirectCollaborators).Parameters
Assert-Equal `
    -Actual $parameters.ContainsKey("forceUserRemoval") `
    -Expected $false `
    -Description "forceUserRemoval parameter presence"

$moduleMetaData = [pscustomobject]@{
    primaryOwnerGitHubHandle   = "primary-owner"
    secondaryOwnerGitHubHandle = "secondary-owner"
}

$null = Remove-DirectCollaborators `
    -orgAndRepoName "Azure/test-repo" `
    -moduleMetaData $moduleMetaData `
    -planOnly $true `
    -issueLog @()

Assert-Equal `
    -Actual ($script:removedUsers -join ",") `
    -Expected "primary-owner,outside-user" `
    -Description "direct collaborator removals"

Write-Host "Teams and users tests passed."
