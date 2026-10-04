# Requires Environment Variables for GitHub Actions
# GH_TOKEN
# TEST_BAMI_* (the eight-field BAMI settings bundle)
# ARM_BACKEND_* (the separate state-only identity and storage)

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$repositoryCreationModeEnabled,
    [string]$stateStorageAccountName = "",
    [string]$stateContainerName = "",
    [string]$stateTenantId = "",
    [string]$stateSubscriptionId = "",
    [string]$stateClientId = "",
    [bool]$planOnly = $false,
    [string]$repoId = "avm-ptn-example-repo",
    [string]$repoUrl = "https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo",
    [string]$outputDirectory = ".",
    [string]$repoConfigFilePath = "../repository-config/config.json",
    [object]$repoMetaData = $null,
    [string]$terraformModulePath = "./terraform",
    [string[]]$resourceTypesThatCannotBeDestroyed = @(
        "github_repository"
    ),
    [switch]$skipCleanup,
    [string[]]$extraTeamsToIgnore = @(
        "security",
        "azurecla-write"
    ),
    [switch]$forceFileUpdate,
    [hashtable]$bamiSettings = @{},
    [string]$repositorySyncRepositoryId = $env:GITHUB_REPOSITORY_ID,
    [string]$stateLayout = $env:AVM_REPOSITORY_SYNC_STATE_LAYOUT
)

$ErrorActionPreference = 'Stop'

# Dot-source the cmdlet libs. `$PSScriptRoot` makes this resolution
# independent of the caller's working directory.
$libDir = Join-Path $PSScriptRoot "lib"
. (Join-Path $libDir "Logging.ps1")
. (Join-Path $libDir "RetryHelpers.ps1")
. (Join-Path $libDir "RepositoryConfig.ps1")
. (Join-Path $libDir "RepoTree.ps1")
. (Join-Path $libDir "AvmPreCommit.ps1")
. (Join-Path $libDir "ManagedFilesUpgrade.ps1")
. (Join-Path $libDir "BranchProtection.ps1")
. (Join-Path $libDir "UnmanagedRulesets.ps1")
. (Join-Path $libDir "CodeQlDefaultSetup.ps1")
. (Join-Path $libDir "TeamsAndUsers.ps1")
. (Join-Path $libDir "TerraformOperations.ps1")
. (Join-Path $libDir "TestTenant.ps1")

if (!$repositoryCreationModeEnabled) {
    $stateBackend = @{
        TenantId = $stateTenantId
        SubscriptionId = $stateSubscriptionId
        ClientId = $stateClientId
        StorageAccountName = $stateStorageAccountName
        ContainerName = $stateContainerName
    }
    $null = Resolve-RepositorySyncStateConfiguration -Backend $stateBackend
}

$issueLog = @()

$moduleName = $repoId

$moduleMetaData = $null

if(!$repositoryCreationModeEnabled){
    $moduleMetaData = $repoMetaData
    if($moduleMetaData) {
        $moduleName = $moduleMetaData.moduleDisplayName
    }
} elseif($repoMetaData) {
    $moduleMetaData = $repoMetaData
    if($moduleMetaData.moduleDisplayName) {
        $moduleName = $moduleMetaData.moduleDisplayName
    }
}

$repositoryConfig = Get-Content -Path $repoConfigFilePath -Raw | ConvertFrom-Json
$settings = Resolve-RepositorySettings -repositoryConfig $repositoryConfig -repoId $repoId
$selectedTestTenant = if ($repositoryCreationModeEnabled) { 'none' } else { $settings.TestTenant }
if (-not $repositoryCreationModeEnabled -and $selectedTestTenant -cne 'bami') {
    throw [System.InvalidOperationException]::new('The legacy test tenant is retired. Normal repository sync requires testTenant bami.')
}
if ($selectedTestTenant -ceq 'bami' -and $env:GITHUB_ACTIONS -eq 'true' -and
    ($env:GITHUB_REPOSITORY -cne 'Azure/azure-verified-modules-tools' -or $env:GITHUB_REF -cne 'refs/heads/main')) {
    throw [System.InvalidOperationException]::new('BAMI repository sync requires trusted Azure/azure-verified-modules-tools main in GitHub Actions.')
}
$testTenant = if ($repositoryCreationModeEnabled) {
    [pscustomobject]@{ TestTenant = 'none'; Settings = $null }
}
else {
    Resolve-RepositoryTestTenantSettings -TestTenant $selectedTestTenant -BamiValues $bamiSettings
}
$repoSplit = $repoUrl.Split("/")
$orgName = $repoSplit[3]
$repoName = $repoSplit[4]
$orgAndRepoName = "$orgName/$repoName"

if (-not $PSCmdlet.ShouldProcess($orgAndRepoName, ($planOnly ? 'Plan repository sync' : 'Apply repository sync'))) {
    return [pscustomobject]@{ Status = 'Preview'; Repository = $orgAndRepoName }
}
if (-not $repositoryCreationModeEnabled) {
    Assert-AvmRepositorySyncStateLayout -Layout $stateLayout
}

Write-Information "Repository: $orgAndRepoName; plan only: $planOnly; force file update: $($forceFileUpdate.IsPresent)." -InformationAction Continue
$discovery = Invoke-RepositorySyncLogGroup -Name 'GitHub repository and team discovery' -Action {
    $context = if ($repositoryCreationModeEnabled) { $null } else {
        Resolve-AvmRepositorySyncContext -RepoId $repoId -Repository $orgAndRepoName `
            -RepositorySyncRepositoryId $repositorySyncRepositoryId
    }
    $tree = if ($repositoryCreationModeEnabled) { $null } else {
        Get-RepositoryDefaultBranchTree -orgAndRepoName $orgAndRepoName
    }
    $teams = Resolve-GitHubTeams -orgName $orgName -orgAndRepoName $orgAndRepoName `
        -teams $settings.Teams -issueLog $issueLog
    @{
        Context = $context
        Tree = $tree
        Teams = $teams.GithubTeams
        IssueLog = @($teams.IssueLog)
    }
}
$repositorySyncContext = $discovery.Context
$repoTree = $discovery.Tree
$githubTeams = $discovery.Teams
$issueLog = @($discovery.IssueLog)

$terraformModulePath = (Resolve-Path -LiteralPath $terraformModulePath).Path
if (!$skipCleanup) {
    Clear-TerraformWorkspace -terraformModulePath $terraformModulePath
}

$terraformVariables = @{
    repository_creation_mode_enabled = $repositoryCreationModeEnabled.IsPresent
    state_layout = $stateLayout
    github_repository_owner = $orgName
    github_repository_name = $repoName
    module_id = $repoId
    module_name = $moduleName
    is_protected_repo = $true
    github_teams = $githubTeams
    pull_request_bypass_teams = $settings.PullRequestBypassTeams
    topics = $settings.Topics
}

if ($null -ne $testTenant.Settings) {
    $terraformVariables["bami_test_settings"] = ConvertTo-AvmRepositoryTerraformSettings -Settings $testTenant.Settings
    $terraformVariables["entra_group_names"] = @($settings.EntraGroups)
}
if ($null -ne $repositorySyncContext) {
    $terraformVariables["repository_sync_repository_id"] = $repositorySyncContext.RepositoryId
}

# Only emit the override when a group actually sets it. Writing a null would
# clobber the Terraform-side default for every other repository.
if ($settings.WorkloadIdentityFederationSubjectClaimOverrides.ContainsKey("jobWorkflowRef")) {
    $terraformVariables["github_job_workflow_ref"] = $settings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"]
}

$terraformVariables | ConvertTo-Json -Depth 100 |
    Set-Content -LiteralPath (Join-Path $terraformModulePath 'terraform.tfvars.json') -Encoding utf8NoBOM

$environment = Get-RepositorySyncTerraformEnvironment -Root $terraformModulePath -Settings $testTenant.Settings
$issueLog = @(Invoke-RepositorySyncLogGroup -Name 'Terraform repository configuration and test identity' -Action {
    $issues = @(Invoke-TerraformInit `
        -terraformModulePath $terraformModulePath `
        -repositoryCreationModeEnabled $repositoryCreationModeEnabled.IsPresent `
        -repoId $repoId `
        -orgAndRepoName $orgAndRepoName `
        -stateStorageAccountName $stateStorageAccountName `
        -stateContainerName $stateContainerName `
        -stateTenantId $stateTenantId `
        -stateSubscriptionId $stateSubscriptionId `
        -stateClientId $stateClientId `
        -environment $environment `
        -issueLog $issueLog)
    $planParameters = @{
        terraformModulePath = $terraformModulePath
        repoId = $repoId
        orgAndRepoName = $orgAndRepoName
        planOnly = $planOnly
        resourceTypesThatCannotBeDestroyed = $resourceTypesThatCannotBeDestroyed
        environment = $environment
        bamiSettings = $testTenant.Settings
        entraGroupNames = @($settings.EntraGroups)
        issueLog = $issues
    }
    if ($null -ne $repositorySyncContext) {
        $planParameters.repository = $repositorySyncContext.Repository
        $planParameters.repositorySyncRepositoryId = $repositorySyncContext.RepositoryId
    }
    if ($settings.WorkloadIdentityFederationSubjectClaimOverrides.ContainsKey('jobWorkflowRef')) {
        $planParameters.jobWorkflowRef = $settings.WorkloadIdentityFederationSubjectClaimOverrides['jobWorkflowRef']
    }
    Invoke-TerraformPlanAndApply @planParameters -Confirm:$false
})
Write-Information ($planOnly ? 'Terraform plan completed; nothing applied.' : 'Terraform apply completed.') -InformationAction Continue

if (!$repositoryCreationModeEnabled) {
    $issueLog = @(Invoke-RepositorySyncLogGroup -Name 'GitHub policy and access cleanup' -Action {
        $issues = @((Remove-LegacyBranchProtection `
            -orgAndRepoName $orgAndRepoName -defaultBranch $repoTree.DefaultBranch `
            -planOnly $planOnly -issueLog $issueLog).IssueLog)
        if ($repoTree -and $repoTree.Success) {
            $issues = @((Remove-UnmanagedRulesets -orgAndRepoName $orgAndRepoName `
                -planOnly $planOnly -issueLog $issues).IssueLog)
            $issues = @((Disable-CodeQlDefaultSetup -orgAndRepoName $orgAndRepoName `
                -planOnly $planOnly -issueLog $issues).IssueLog)
        }
        $issues = @(Remove-DirectCollaborators -orgAndRepoName $orgAndRepoName `
            -moduleMetaData $moduleMetaData -planOnly $planOnly -issueLog $issues)
        Remove-UnmanagedRepositoryTeams -orgName $orgName -orgAndRepoName $orgAndRepoName `
            -githubTeams $githubTeams -extraTeamsToIgnore $extraTeamsToIgnore -planOnly $planOnly -issueLog $issues
    })
}

# Run the complete authoring pre-commit gauntlet after Terraform succeeds. Managed
# files are fetched per repository so each one resolves the release tag recorded in
# its own .avm/managed-files-version.json.
if (!$repositoryCreationModeEnabled) {
    if (@($issueLog | Where-Object { $_.severity -ne 'warning' }).Count -gt 0) {
        Write-Warning "Skipping file updates for $orgAndRepoName because repository sync reported errors."
    } else {
        $preCommitResult = Invoke-RepositorySyncLogGroup -Name 'Managed files and authoring checks' -Action {
            Invoke-AvmPreCommitForRepository `
            -orgAndRepoName $orgAndRepoName `
            -repoId $repoId `
            -repositoryConfigDir (Split-Path -Parent (Resolve-Path $repoConfigFilePath).Path) `
            -codeOwnersDefaultTeams $settings.CodeOwnersDefaultTeams `
            -codeOwnersFileProtectionTeams $settings.CodeOwnersFileProtectionTeams `
            -defaultBranch $repoTree.DefaultBranch `
            -planOnly $planOnly `
            -forceFileUpdate $forceFileUpdate.IsPresent `
            -issueLog $issueLog
        }
        $issueLog = @($preCommitResult.IssueLog)
        Write-Information ($preCommitResult.HasChanges ? 'Managed-file changes prepared.' : 'Managed files are unchanged.') -InformationAction Continue
    }
}

if ($issueLog.Count -eq 0) {
    Write-Information "Repository sync completed for $orgAndRepoName." -InformationAction Continue
} else {
    ConvertTo-Json -InputObject $issueLog -Depth 100 |
        Set-Content -LiteralPath (Join-Path $outputDirectory 'issue.log.json') -Encoding utf8NoBOM
    foreach ($issue in $issueLog) {
        Write-Warning "$($issue.message)"
    }
    if (@($issueLog | Where-Object { $_.severity -ne 'warning' }).Count -gt 0) {
        throw [System.InvalidOperationException]::new("Repository sync reported errors for $orgAndRepoName; see issue.log.json.")
    }
}
$global:LASTEXITCODE = 0
