#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'AvmPreCommit.ps1')
    . (Join-Path $repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'ManagedFilesUpgrade.ps1')
}

Describe 'Component: Terraform metadata input collection' -Tag Component {
    BeforeEach {
        Mock Invoke-RepositoryGitHubApi { [pscustomobject]@{ sha = 'a' * 40 } }
        Mock Get-RepositoryFileAtCommit {
            [pscustomobject]@{
                Content = "ModuleName,ModuleDisplayName,Description,RepoURL`navm-res-storage-account,Storage Account,Creates storage.,https://github.com/Azure/terraform-azurerm-avm-res-storage-account`n"
            }
        }
    }

    It 'gets current CSV metadata at an immutable commit without a registration file' {
        $context = Get-AvmRepositoryMetadataBackfillContext -orgAndRepoName 'Azure/terraform-azurerm-avm-res-storage-account'
        $context.SourceSha | Should -Be ('a' * 40)
        $context.LegacyRecord.Count | Should -Be 1
        $context.LegacyRecord[0].Description | Should -Be 'Creates storage.'
        $context.ContainsKey('SeedPath') | Should -BeFalse
        Should -Invoke Get-RepositoryFileAtCommit -Exactly 1 -ParameterFilter {
            $Repository -ceq 'Azure/Azure-Verified-Modules' -and
            $Path -ceq 'docs/static/module-indexes/TerraformResourceModules.csv' -and $Sha -ceq ('a' * 40)
        }
    }

    It 'refuses an invalid index commit rather than using an unpinned response' {
        Mock Invoke-RepositoryGitHubApi { [pscustomobject]@{ sha = 'main' } }
        { Get-AvmRepositoryMetadataBackfillContext -orgAndRepoName 'Azure/terraform-azurerm-avm-res-storage-account' } |
            Should -Throw '*commit is missing or invalid*'
        Should -Invoke Get-RepositoryFileAtCommit -Times 0
    }
}

Describe 'Component: Terraform metadata workflow scope' -Tag Component {
    It 'enables backfill only for an explicit workflow_dispatch input and keeps CI credential checks' {
        $workflow = Get-Content (Join-Path $repoRoot '.github' 'workflows' 'repository-management-sync.yml') -Raw
        $expression = "METADATA_BACKFILL_ENABLED: \$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.metadata_backfill \|\| false \}\}"
        [regex]::Matches($workflow, $expression).Count | Should -Be 2
        $workflow | Should -Match '(?s)metadata_backfill:.*?default: false\s+type: boolean'
        $workflow | Should -Not -Match 'AVM_SYNC_PAUSED'
        $ci = Get-Content (Join-Path $repoRoot '.github' 'workflows' 'ci.yml') -Raw
        $ci | Should -Match "if:.*vars\.ARM_CLIENT_ID != ''"
    }

    It 'loads branch code for metadata creation and skips Azure state, settings, and project changes' {
        $workflow = Get-Content (Join-Path $repoRoot '.github' 'workflows' 'repository-management-sync.yml') -Raw
        $driver = Get-Content (Join-Path $repoRoot 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositorySync.ps1') -Raw
        $workflow | Should -Match "(?s)METADATA_BACKFILL_ENABLED -eq 'true'.*?Import-Module \(Join-Path .*?'src' 'Avm.Authoring' 'Avm.Authoring.psd1'\)"
        foreach ($step in @('Setup Terraform', 'Resolve state backend', 'Azure Login for state \(OIDC\)', 'Download Labels CSV File')) {
            $workflow | Should -Match ("(?s)- name: " + $step + "\s+if:.*?!inputs.metadata_backfill")
        }
        $workflow | Should -Match 'inputs.sync_project_items && !inputs.metadata_backfill'
        $driver.IndexOf('return Invoke-AvmPreCommitForRepository') |
            Should -BeLessThan $driver.IndexOf('$env:ARM_USE_AZUREAD = "true"')
        $driver.IndexOf('return Invoke-AvmPreCommitForRepository') |
            Should -BeLessThan $driver.IndexOf('Resolve-RepositoryTestTenantSettings')
        $workflow | Should -Match "-bamiTestTenantSyncEnabled \(\`$env:AVM_BAMI_TEST_TENANT_SYNC_ENABLED -ceq 'true' -and -not \`$metadataBackfill\)"
        $workflow | Should -Not -Match 'reviewed-seeds|SeedManifestPath'
    }

    It 'does not parse legacy or BAMI tenant values during metadata backfill' {
        $workflow = Get-Content (Join-Path $repoRoot '.github' 'workflows' 'repository-management-sync.yml') -Raw
        $start = $workflow.IndexOf('          $testSubscriptionIds = @()')
        $start | Should -BeGreaterThan 0
        $end = $workflow.IndexOf('          $repoMetaDataJson', $start)
        $end | Should -BeGreaterThan $start
        $source = $workflow.Substring($start, $end - $start)
        $probe = [scriptblock]::Create($source + "`n[pscustomobject]@{ Subscriptions = `$testSubscriptionIds; Bami = `$bamiSettings }")
        $savedSubscriptions = $env:TEST_SUBSCRIPTION_IDS
        $savedBamiSubscriptions = $env:TEST_BAMI_SUBSCRIPTION_IDS
        $savedBamiTenant = $env:TEST_BAMI_TENANT_ID
        try {
            $metadataBackfill = $true
            $env:TEST_SUBSCRIPTION_IDS = 'invalid JSON must not be parsed'
            $env:TEST_BAMI_SUBSCRIPTION_IDS = 'invalid BAMI JSON must not be parsed'
            $env:TEST_BAMI_TENANT_ID = 'unused-bami-tenant'
            $result = & $probe
            $result.Subscriptions | Should -HaveCount 0
            $result.Bami.Count | Should -Be 0

            $metadataBackfill = $false
            $env:TEST_SUBSCRIPTION_IDS = '["legacy-subscription"]'
            $result = & $probe
            @($result.Subscriptions) | Should -Be @('legacy-subscription')
            $result.Bami.Count | Should -Be 8
            $result.Bami.TEST_BAMI_TENANT_ID | Should -BeExactly 'unused-bami-tenant'
            $result.Bami.TEST_BAMI_SUBSCRIPTION_IDS | Should -BeExactly 'invalid BAMI JSON must not be parsed'
        }
        finally {
            [Environment]::SetEnvironmentVariable('TEST_SUBSCRIPTION_IDS', $savedSubscriptions)
            [Environment]::SetEnvironmentVariable('TEST_BAMI_SUBSCRIPTION_IDS', $savedBamiSubscriptions)
            [Environment]::SetEnvironmentVariable('TEST_BAMI_TENANT_ID', $savedBamiTenant)
        }
    }
}

Describe 'Component: metadata backfill repository sync' -Tag Component {
    BeforeEach {
        $script:originalEvent = $env:GITHUB_EVENT_NAME
        $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
        $script:events = [System.Collections.Generic.List[string]]::new()
        $script:existingReview = $false
        $script:existingBranch = $false
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:root
        Mock Import-Module {}
        Mock Get-AvmRepositoryMetadataBackfillContext { @{ LegacyRecord = @(@{ ModuleDisplayName = 'Example' }); SourceSha = 'a' * 40 } }
        Mock Invoke-RepositoryGitHub {
            if ($script:existingReview) { [pscustomobject]@{ number = 42; url = 'https://github.com/Azure/example/pull/42' } }
        }
        Mock Get-RepositoryBranchHead { if ($script:existingBranch) { 'b' * 40 } }
        Mock Invoke-AvmMetadataBackfillPreparation {
            $script:events.Add('metadata')
            [System.IO.File]::WriteAllText((Join-Path $Context.Root 'metadata.json'), '{}')
            [pscustomobject]@{ Status = 'pass'; Modules = @(); UpdateSource = $Context.State.UpdateSource }
        }
        Mock Invoke-RepositoryFileSync {
            param($Repository, $PlanOnly, $Prepare, $State, $ReviewOnly)
            $script:events.Add('clone')
            & $Prepare @{ Root = $script:root; Repository = @{ full_name = $Repository }; State = $State; PlanOnly = [bool]$PlanOnly }
            @{
                HasChanges = $true
                Status = if ($PlanOnly) { 'Planned' } elseif ($ReviewOnly) { 'ReviewRequired' } else { 'Merged' }
                PullRequestUrl = if ($PlanOnly) { $null } else { 'https://github.com/Azure/example/pull/43' }
            }
        }
        Mock Remove-AvmMetadataFileConflict { $false }
        Mock Set-TerraformCodeowners {}
        Mock Resolve-AvmManagedFilesUpgradeDecision { @{ Upgrade = $false; Reason = 'unchanged' } }
        Mock Invoke-AvmPreCommitWithUpgradeRetry {
            $script:events.Add('pre-commit')
            [pscustomobject]@{ Status = 'pass'; Steps = @() }
        }
        $script:parameters = @{
            orgAndRepoName = 'Azure/terraform-azurerm-avm-res-example-resource'
            repoId = 'avm-res-example-resource'
            repositoryConfigDir = $TestDrive
            codeOwnersDefaultTeams = @()
            codeOwnersFileProtectionTeams = @('azure-verified-modules-engineering-owners')
            defaultBranch = 'main'
            planOnly = $false
            issueLog = @()
        }
    }

    AfterEach { $env:GITHUB_EVENT_NAME = $script:originalEvent }

    It 'preserves the normal Terraform sync behavior when metadata creation is not selected' {
        $result = Invoke-AvmPreCommitForRepository @script:parameters -forceFileUpdate $true
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $script:events | Should -Be @('clone', 'pre-commit')
        Should -Invoke Import-Module -Exactly 1 -ParameterFilter { $Name -ceq 'Avm.Authoring' -and $ErrorAction -eq 'Stop' }
        Should -Invoke Get-AvmRepositoryMetadataBackfillContext -Times 0
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter { -not $ReviewOnly -and -not $StableBranch }
    }

    It 'creates metadata without running unrelated formatters or managed-file changes' {
        $result = Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true
        $script:events | Should -Be @('clone', 'metadata')
        Should -Invoke Import-Module -Exactly 0
        Should -Invoke Remove-AvmMetadataFileConflict -Times 0
        Should -Invoke Set-TerraformCodeowners -Times 0
        Should -Invoke Resolve-AvmManagedFilesUpgradeDecision -Times 0
        Should -Invoke Invoke-AvmPreCommitWithUpgradeRetry -Times 0
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter {
            $ReviewOnly -and $VerifyCandidate -and $StableBranch -ceq 'avm-bot/module-metadata-backfill' -and
            $ExpectedActor.id -eq 187664033 -and $Title -notmatch '\[skip ci\]'
        }
        $result.BackfillReviewUrl | Should -Be 'https://github.com/Azure/example/pull/43'
    }

    It 'keeps a metadata dry run from requesting publication' {
        $script:parameters.planOnly = $true
        $result = Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true
        $result.BackfillReviewUrl | Should -BeNullOrEmpty
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter { $PlanOnly -and $ReviewOnly -and -not $State.UpdateSource }
    }

    It 'defers existing reviews and branches without overwriting them: <Existing>' -TestCases @(
        @{ Existing = 'review' }, @{ Existing = 'branch' }
    ) {
        param($Existing)
        $script:existingReview = $Existing -eq 'review'
        $script:existingBranch = $Existing -eq 'branch'
        (Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true).BackfillDeferred | Should -BeTrue
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }

    It 'rejects non-manual metadata activation: <Event>' -TestCases @(
        @{ Event = 'schedule' }, @{ Event = 'repository_dispatch' }, @{ Event = 'push' }, @{ Event = 'workflow_run' }
    ) {
        param($Event)
        $env:GITHUB_EVENT_NAME = $Event
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw '*manual-only*'
        Should -Invoke Invoke-RepositoryGitHub -Times 0
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }

    It 'requires explicit metadata creation before source changes are permitted' {
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataUpdateSource $true } | Should -Throw '*requires explicit metadataBackfill*'
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }
}

Describe 'Component: metadata backfill checkout module loading' -Tag Component {
    It 'prepares metadata with no installed module in a fresh process: planOnly=<PlanOnly>' -ForEach @(
        @{ PlanOnly = 'true' }
        @{ PlanOnly = 'false' }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $child = @'
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
if (Get-Module Avm.Authoring) { throw 'The child must start without Avm.Authoring loaded.' }
if (@(Get-Module -ListAvailable Avm.Authoring).Count -ne 0) { throw 'Avm.Authoring must not be discoverable by name.' }
$manifest = Join-Path $env:BACKFILL_TOOLS_ROOT 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
Import-Module $manifest -Force -ErrorAction Stop
$modulePath = Join-Path $env:BACKFILL_TOOLS_ROOT 'src' 'Avm.Authoring' 'Avm.Authoring.psm1'
if ((Get-Module Avm.Authoring).Path -cne $modulePath) { throw 'The trusted checkout module was not loaded.' }
. (Join-Path $env:BACKFILL_TOOLS_ROOT 'repository-management' 'repository-sync' 'scripts' 'lib' 'AvmPreCommit.ps1')

$repository = 'Azure/terraform-azurerm-avm-ptn-example-repo'
$csv = "ModuleName,ModuleDisplayName,Description,RepoURL,PrimaryModuleOwnerGHHandle`navm-ptn-example-repo,Example module,Creates example resources.,https://github.com/$repository,example-owner`n"
function Invoke-RepositoryGitHubApi {
    param($Endpoint)
    if ($Endpoint -cne 'repos/Azure/Azure-Verified-Modules/commits/main') { throw "Unexpected API read: $Endpoint" }
    [pscustomobject]@{ sha = 'a' * 40 }
}
function Get-RepositoryFileAtCommit {
    param($Repository, $Path, $Sha)
    if ($Repository -cne 'Azure/Azure-Verified-Modules' -or
        $Path -cne 'docs/static/module-indexes/TerraformPatternModules.csv' -or $Sha -cne ('a' * 40)) {
        throw 'Unexpected metadata index read.'
    }
    [pscustomobject]@{ Content = $csv }
}
function Invoke-RepositoryGitHub {
    param($Arguments, [switch] $AsJson)
    if (-not $AsJson -or ($Arguments -join ' ') -cne "pr list --repo=$repository --state=open --head=avm-bot/module-metadata-backfill --json=number,url") {
        throw 'Unexpected GitHub operation.'
    }
}
function Get-RepositoryBranchHead {
    param($Repository, $Branch)
    if ($Repository -cne $script:repository -or $Branch -cne 'avm-bot/module-metadata-backfill') { throw 'Unexpected branch read.' }
}
function Invoke-RepositoryGit { throw 'No real Git operation is allowed.' }
function Install-PSResource { throw 'Metadata backfill must not install a module.' }
function Update-PSResource { throw 'Metadata backfill must not upgrade a module.' }
function Invoke-AvmPreCommitWithUpgradeRetry { throw 'Metadata backfill must not run ordinary pre-commit.' }
function Invoke-RepositoryFileSync {
    param($Repository, $DefaultBranch, [switch] $PlanOnly, $State, $Prepare,
        $StableBranch, [switch] $ReviewOnly, [switch] $VerifyCandidate, $ExpectedActor, $Title, $Body)

    if ($PlanOnly.IsPresent -ne ($env:BACKFILL_PLAN_ONLY -ceq 'true') -or
        -not $ReviewOnly -or -not $VerifyCandidate -or $ExpectedActor.id -ne 187664033 -or
        $StableBranch -cne 'avm-bot/module-metadata-backfill' -or $State.CodeownersContent -or $State.UpdateSource) {
        throw 'Unexpected metadata publication options.'
    }
    Push-Location $env:BACKFILL_TEST_ROOT
    try {
        & $Prepare @{
            Root = $env:BACKFILL_TEST_ROOT
            Repository = @{ full_name = $Repository }
            State = $State
            PlanOnly = $PlanOnly.IsPresent
        }
    }
    finally { Pop-Location }
    @{
        HasChanges = Test-Path -LiteralPath (Join-Path $env:BACKFILL_TEST_ROOT 'metadata.json')
        PullRequestUrl = if ($PlanOnly) { $null } else { 'https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo/pull/1' }
    }
}

$source = "locals { unrelated = true }`n"
[System.IO.File]::WriteAllText((Join-Path $env:BACKFILL_TEST_ROOT 'main.tf'), $source)
$standalone = Join-Path $env:BACKFILL_TOOLS_ROOT 'repository-management' 'module-metadata' 'Invoke-ModuleMetadataBackfill.ps1'
$preview = & $standalone -RepositoryRoot $env:BACKFILL_TEST_ROOT -Repository $repository -Ecosystem terraform `
    -LegacyRecord @(ConvertFrom-AvmMetadataIndex -Content $csv) -UpdateSource -WhatIf
if ($preview.Status -cne 'planned' -or $preview.Changed -or
    (Test-Path -LiteralPath (Join-Path $env:BACKFILL_TEST_ROOT 'metadata.json')) -or
    (Test-Path -LiteralPath (Join-Path $env:BACKFILL_TEST_ROOT 'main.metadata.tf'))) {
    throw 'Standalone WhatIf must plan without writing metadata or source readers.'
}
$result = Invoke-AvmPreCommitForRepository -orgAndRepoName $repository -repoId 'avm-ptn-example-repo' `
    -repositoryConfigDir $env:BACKFILL_TEST_ROOT -codeOwnersDefaultTeams @() -codeOwnersFileProtectionTeams @() `
    -defaultBranch main -planOnly ($env:BACKFILL_PLAN_ONLY -ceq 'true') -metadataBackfill $true -issueLog @()
if ((Get-Command Initialize-AvmModuleMetadata -Module Avm.Authoring).Module.Path -cne $modulePath -or
    @(Get-Module -ListAvailable Avm.Authoring).Count -ne 0 -or $env:PSModulePath -cne (Join-Path $PSHOME 'Modules')) {
    throw 'Preparation must retain the checkout module without changing module discovery.'
}
if ((Get-Content -LiteralPath (Join-Path $env:BACKFILL_TEST_ROOT 'main.tf') -Raw) -cne $source -or
    (Test-Path -LiteralPath (Join-Path $env:BACKFILL_TEST_ROOT 'main.metadata.tf'))) {
    throw 'Default metadata preparation must leave source unchanged.'
}
[pscustomobject]@{
    Result = $result
    Preview = $preview
    Metadata = Get-Content -LiteralPath (Join-Path $env:BACKFILL_TEST_ROOT 'metadata.json') -Raw | ConvertFrom-Json
} | ConvertTo-Json -Depth 10 -Compress
'@
        $modulePath = Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psm1'
        $module = Get-Module Avm.Authoring | Where-Object { $_.Path -ceq $modulePath } | Select-Object -First 1
        $output = & $module {
            param($Executable, $Code, $ToolsRoot, $FixtureRoot, $Plan)
            Invoke-AvmProcess -FilePath $Executable -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $Code) `
                -TimeoutSec 60 -EnvVars @{
                    BACKFILL_TOOLS_ROOT = $ToolsRoot
                    BACKFILL_TEST_ROOT = $FixtureRoot
                    BACKFILL_PLAN_ONLY = $Plan
                    PSModulePath = Join-Path $PSHOME 'Modules'
                    AVM_OFFLINE = '1'
                    GITHUB_EVENT_NAME = 'workflow_dispatch'
                    GITHUB_ACTIONS = 'true'
                    GH_TOKEN = $null
                    GITHUB_TOKEN = $null
                }
        } $pwsh $child $repoRoot $root $PlanOnly
        $output.ExitCode | Should -Be 0
        $report = ($output.StdOut.TrimEnd() -split '\r?\n')[-1] | ConvertFrom-Json
        $report.Result.HasChanges | Should -BeTrue
        $report.Result.MetadataBackfill.Status | Should -BeExactly 'pass'
        $report.Result.MetadataBackfill.Modules | Should -HaveCount 1
        $report.Result.MetadataBackfill.Modules[0].Changed | Should -BeTrue
        $report.Preview.Modules[0].PlannedFiles | Should -Be @('metadata.json', 'main.metadata.tf')
        $report.Metadata.canonicalType | Should -BeExactly 'example/repo'
        $report.Metadata.moduleDescription | Should -BeExactly 'Creates example resources.'
        $report.Metadata.owners | Should -Be @('example-owner')
        if ($PlanOnly -ceq 'true') {
            $report.Result.BackfillReviewUrl | Should -BeNullOrEmpty
        } else {
            $report.Result.BackfillReviewUrl | Should -BeExactly 'https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo/pull/1'
        }
    }
}
