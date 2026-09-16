# Requires Environment Variables for GitHub Actions
# GH_TOKEN
# ARM_USE_AZUREAD
# ARM_USE_OIDC
# ARM_TENANT_ID
# ARM_SUBSCRIPTION_ID
# ARM_CLIENT_ID
# Must run gh auth login -h "GitHub.com" before running this script

param(
    [switch]$repositoryCreationModeEnabled,
    [string]$stateStorageAccountName = "",
    [string]$stateContainerName = "",
    [string]$stateTenantId = "",
    [string]$stateSubscriptionId = "",
    [string]$stateClientId = "",
    [string]$identityResourceGroupName = "",
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
    [switch]$metadataBackfill,
    [switch]$metadataUpdateSource,
    [string]$managementGroupId = "",
    [array]$testSubscriptionIds = @(),
    [bool]$bamiTestTenantSyncEnabled = $false,
    [hashtable]$bamiSettings = @{}
)

if ($metadataUpdateSource -and -not $metadataBackfill) {
    throw [System.ArgumentException]::new('metadataUpdateSource requires explicit metadataBackfill opt-in.')
}
if ($metadataBackfill -and $env:GITHUB_EVENT_NAME -and $env:GITHUB_EVENT_NAME -ne 'workflow_dispatch') {
    throw [System.InvalidOperationException]::new('Metadata backfill is manual-only; scheduled and repository_dispatch runs cannot enable it.')
}

Write-Host "Running repo sync script"

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

if ($metadataBackfill) {
    if ($repositoryCreationModeEnabled) {
        throw [System.ArgumentException]::new('One-off metadata backfill only supports existing module repositories.')
    }
    $uri = [uri]$repoUrl
    if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'github.com') {
        throw [System.ArgumentException]::new('Metadata creation requires an HTTPS GitHub repository URL.')
    }
    $backfillRepo = $uri.AbsolutePath.Trim('/')
    $tree = Get-RepositoryDefaultBranchTree -orgAndRepoName $backfillRepo
    if (-not $tree.Success) {
        throw [System.InvalidOperationException]::new('Cannot resolve the target repository for metadata creation.')
    }
    return Invoke-AvmPreCommitForRepository `
        -orgAndRepoName $backfillRepo `
        -repoId $repoId `
        -repositoryConfigDir (Split-Path -Parent (Resolve-Path $repoConfigFilePath).Path) `
        -codeOwnersDefaultTeams @() `
        -codeOwnersFileProtectionTeams @() `
        -defaultBranch $tree.DefaultBranch `
        -planOnly $planOnly `
        -metadataBackfill $true `
        -metadataUpdateSource $metadataUpdateSource.IsPresent `
        -issueLog @()
}

if (!$repositoryCreationModeEnabled) {
    $null = Resolve-RepositorySyncStateIdentity `
        -TenantId $stateTenantId -SubscriptionId $stateSubscriptionId -ClientId $stateClientId
}

$env:ARM_USE_AZUREAD = "true"

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
$selectedTestTenant = if ($repositoryCreationModeEnabled) { 'legacy' } else { $settings.TestTenant }
$testTenant = Resolve-RepositoryTestTenantSettings -TestTenant $selectedTestTenant `
    -Enabled $bamiTestTenantSyncEnabled -BamiValues $bamiSettings
if ($testTenant.Status -ceq 'PendingTestTenantActivation') {
    Write-Warning "${repoId}: BAMI activation is disabled. Repository settings are unchanged; select legacy in configuration for an explicit rollback."
    return [pscustomobject]@{ Status = $testTenant.Status; RepoId = $repoId; TestTenant = 'bami' }
}
Write-Host "$([Environment]::NewLine)Checking $($repoId)"

if(!$skipCleanup) {
    Clear-TerraformWorkspace -terraformModulePath $terraformModulePath
}

$repoSplit = $repoUrl.Split("/")
$orgName = $repoSplit[3]
$repoName = $repoSplit[4]
$orgAndRepoName = "$orgName/$repoName"

$candidateSettings = $null
if ($testTenant.TestTenant -ceq 'bami') {
    $candidateParameters = @{
        RepoId = $repoId
        Repository = $orgAndRepoName
        BamiValues = $testTenant.Settings
        Backend = @{
            TenantId = $stateTenantId
            SubscriptionId = $stateSubscriptionId
            ClientId = $stateClientId
            StorageAccountName = $stateStorageAccountName
            ContainerName = $stateContainerName
        }
        Root = [System.IO.Path]::GetFullPath((Join-Path $terraformModulePath '..' 'bami-identity'))
        PlanOnly = $planOnly
    }
    if ($settings.WorkloadIdentityFederationSubjectClaimOverrides.ContainsKey("jobWorkflowRef")) {
        $candidateParameters.JobWorkflowRef = $settings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"]
    }
    $candidate = Invoke-AvmBamiRepositoryIdentity @candidateParameters
    if ($candidate.Status -cne 'Ready') {
        Write-Warning "${orgAndRepoName}: $($candidate.Status). The consumer update is pending; no repository settings were changed."
        return $candidate
    }
    $candidateSettings = $candidate.ConsumerSettings
}
Write-Host "$([Environment]::NewLine)<--->" -ForegroundColor Green
Write-Host "$([Environment]::NewLine)Updating: $orgAndRepoName.$([Environment]::NewLine)" -ForegroundColor Green
Write-Host "<--->$([Environment]::NewLine)" -ForegroundColor Green

$repoTree = if (!$repositoryCreationModeEnabled) {
    Get-RepositoryDefaultBranchTree -orgAndRepoName $orgAndRepoName
} else {
    $null
}

# Remove any legacy classic branch-protection rule from the target repo
# before anything else - every AVM repo must be governed exclusively by
# the rulesets defined in modules/github/github.rulesets.tf.
if(!$repositoryCreationModeEnabled) {
    $branchProtectionResult = Remove-LegacyBranchProtection `
        -orgAndRepoName $orgAndRepoName `
        -defaultBranch $repoTree.DefaultBranch `
        -planOnly $planOnly `
        -issueLog $issueLog
    $issueLog = $branchProtectionResult.IssueLog
}

# Remove any repository-level rulesets that were not created by our
# Terraform automation. modules/github/github.rulesets.tf owns the three
# rulesets every AVM repo must have; anything else at the repo scope was
# added out-of-band and silently shadows / weakens those policies.
# Org-level rulesets are NOT enumerated (includes_parents=false) and are
# additionally filtered out by source_type, so the org-wide governance
# ruleset is never at risk.
if(!$repositoryCreationModeEnabled -and $repoTree -and $repoTree.Success) {
    $unmanagedRulesetsResult = Remove-UnmanagedRulesets `
        -orgAndRepoName $orgAndRepoName `
        -planOnly $planOnly `
        -issueLog $issueLog
    $issueLog = $unmanagedRulesetsResult.IssueLog
}

# Disable GitHub's CodeQL "default setup" so the only CodeQL workflow on
# the repo is the advanced-setup `.github/workflows/codeql.yml` we ship
# via managed files. Default setup spawns a dynamic
# `dynamic/github-code-scanning/codeql` workflow that (a) duplicates the
# `/language:actions` SARIF category our managed workflow already covers
# and (b) cannot satisfy the customized OIDC subject template because its
# dynamic jobs do not attach to a deployment environment, so it fails on
# every push. The PATCH is idempotent (no-op if already off).
if(!$repositoryCreationModeEnabled -and $repoTree -and $repoTree.Success) {
    $codeQlDefaultSetupResult = Disable-CodeQlDefaultSetup `
        -orgAndRepoName $orgAndRepoName `
        -planOnly $planOnly `
        -issueLog $issueLog
    $issueLog = $codeQlDefaultSetupResult.IssueLog
}

$resolveTeamsResult = Resolve-GitHubTeams `
    -orgName $orgName `
    -orgAndRepoName $orgAndRepoName `
    -teams $settings.Teams `
    -issueLog $issueLog
$githubTeams = $resolveTeamsResult.GithubTeams
$issueLog = $resolveTeamsResult.IssueLog

if(!$repositoryCreationModeEnabled) {
    Write-Host "Checking repository: $orgAndRepoName for existing teams and users."
    $issueLog = Remove-DirectCollaborators `
        -orgAndRepoName $orgAndRepoName `
        -moduleMetaData $moduleMetaData `
        -planOnly $planOnly `
        -issueLog $issueLog

    $issueLog = Remove-UnmanagedRepositoryTeams `
        -orgName $orgName `
        -orgAndRepoName $orgAndRepoName `
        -githubTeams $githubTeams `
        -extraTeamsToIgnore $extraTeamsToIgnore `
        -planOnly $planOnly `
        -issueLog $issueLog
}

Write-Host "Using test subscription IDs:"
Write-Host $($testSubscriptionIds | ConvertTo-Json)

$terraformVariables = @{
    repository_creation_mode_enabled = $repositoryCreationModeEnabled.IsPresent
    github_repository_owner = $orgName
    github_repository_name = $repoName
    module_id = $repoId
    module_name = $moduleName
    management_group_id = $managementGroupId
    test_subscription_ids = $testSubscriptionIds
    identity_resource_group_name = $identityResourceGroupName
    is_protected_repo = $true
    github_teams = $githubTeams
    topics = $settings.Topics
}

if ($null -ne $candidateSettings) {
    $terraformVariables["bami_test_settings"] = $candidateSettings
}

# Only emit the override when a group actually sets it. Writing a null would
# clobber the Terraform-side default for every other repository.
if ($settings.WorkloadIdentityFederationSubjectClaimOverrides.ContainsKey("jobWorkflowRef")) {
    $terraformVariables["github_job_workflow_ref"] = $settings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"]
}

$terraformVariables | ConvertTo-Json -Depth 100 | Out-File "$terraformModulePath/terraform.tfvars.json"

$preTerraformIssueCount = $issueLog.Count

$issueLog = Invoke-TerraformInit `
    -terraformModulePath $terraformModulePath `
    -repositoryCreationModeEnabled $repositoryCreationModeEnabled.IsPresent `
    -repoId $repoId `
    -orgAndRepoName $orgAndRepoName `
    -stateStorageAccountName $stateStorageAccountName `
    -stateContainerName $stateContainerName `
    -stateTenantId $stateTenantId `
    -stateSubscriptionId $stateSubscriptionId `
    -stateClientId $stateClientId `
    -issueLog $issueLog

$issueLog = Invoke-TerraformPlanAndApply `
    -terraformModulePath $terraformModulePath `
    -repoId $repoId `
    -orgAndRepoName $orgAndRepoName `
    -planOnly $planOnly `
    -resourceTypesThatCannotBeDestroyed $resourceTypesThatCannotBeDestroyed `
    -stateStorageAccountName $stateStorageAccountName `
    -stateContainerName $stateContainerName `
    -stateSubscriptionId $stateSubscriptionId `
    -issueLog $issueLog

# Run the complete authoring pre-commit gauntlet after Terraform succeeds. Managed
# files are fetched per repository so each one resolves the release tag recorded in
# its own .avm/managed-files-version.json.
if(!$repositoryCreationModeEnabled) {
    if($issueLog.Count -gt $preTerraformIssueCount) {
        Write-Host "Skipping avm pre-commit for $orgAndRepoName because terraform reported issues for this run." -ForegroundColor Yellow
    } else {
        $preCommitResult = Invoke-AvmPreCommitForRepository `
            -orgAndRepoName $orgAndRepoName `
            -repoId $repoId `
            -repositoryConfigDir (Split-Path -Parent (Resolve-Path $repoConfigFilePath).Path) `
            -codeOwnersDefaultTeams $settings.CodeOwnersDefaultTeams `
            -codeOwnersFileProtectionTeams $settings.CodeOwnersFileProtectionTeams `
            -defaultBranch $repoTree.DefaultBranch `
            -planOnly $planOnly `
            -forceFileUpdate $forceFileUpdate.IsPresent `
            -metadataBackfill $metadataBackfill.IsPresent `
            -metadataUpdateSource $metadataUpdateSource.IsPresent `
            -issueLog $issueLog
        $issueLog = $preCommitResult.IssueLog
    }
}

if($issueLog.Count -eq 0) {
    Write-Host "No issues found for $repoId"
} else {
    Write-Host "Issues found for $repoId"
    $issueLogJson = ConvertTo-Json $issueLog -Depth 100
    $issueLogJson | Out-File "$outputDirectory/issue.log.json"
}
