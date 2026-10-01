BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $sharedLib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    $lib = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'lib'
    . (Join-Path $sharedLib 'RetryHelpers.ps1')
    . (Join-Path $sharedLib 'RepoTree.ps1')
    . (Join-Path $sharedLib 'RepositoryDiscovery.ps1')
    . (Join-Path $lib 'RepositoryFileAccess.ps1')
    . (Join-Path $lib 'ModuleOwners.ps1')
    . (Join-Path $lib 'RunSummary.ps1')
    . (Join-Path $lib 'PrReviewerRouting.ps1')
    . (Join-Path $lib 'PrReviewerRoutingDiscovery.ps1')
    Set-StrictMode -Version 3.0

    $script:terraformRoutingRepository = 'Azure/terraform-azure-avm-res-storage-storageaccount'
    $script:secondTerraformRoutingRepository = 'Azure/terraform-azurerm-avm-res-keyvault-vault'

    function New-TerraformRoutingPullRequest {
        param([int] $Number = 1)
        [pscustomobject]@{
            author = [pscustomobject]@{ login = 'contributor' }
            number = $Number
            url = "https://github.com/$script:terraformRoutingRepository/pull/$Number"
            isDraft = $false
            reviewRequests = @()
            reviews = @()
            headRefOid = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
            labels = @()
            state = 'OPEN'
        }
    }

    function New-TerraformRoutingSearchItem {
        param(
            [int] $Number = 1,
            [string] $Repository = $script:terraformRoutingRepository
        )
        [pscustomobject]@{
            number = $Number
            html_url = "https://github.com/$Repository/pull/$Number"
            pull_request = [pscustomobject]@{}
        }
    }

    function New-InstalledRoutingRepository {
        param([int] $Number)
        [pscustomobject]@{
            full_name = "Azure/terraform-azure-avm-res-module-$Number"
        }
    }
}

Describe 'Terraform reviewer routing installation pagination' {
    BeforeEach {
        $script:terraformRoutingInstallationPages = @{
            1 = [pscustomobject]@{
                total_count = 101
                repositories = @(1..100 | ForEach-Object { New-InstalledRoutingRepository -Number $_ })
            }
            2 = [pscustomobject]@{
                total_count = 101
                repositories = @((New-InstalledRoutingRepository -Number 101))
            }
        }
        Mock Invoke-RepositorySyncProcess {
            param($Arguments)
            $pageMatch = [regex]::Match($Arguments[-1], 'page=(\d+)$')
            $page = [int]$pageMatch.Groups[1].Value
            [pscustomobject]@{
                ExitCode = 0
                StdOut = ($script:terraformRoutingInstallationPages[$page] | ConvertTo-Json -Depth 8)
                StdErr = ''
            }
        }
    }

    It 'retrieves all installed repositories before filtering routing targets' {
        $repositories = @(Get-RepositoryInstalledRepositories)
        $repositories | Should -HaveCount 101
        $repositories[-1].full_name | Should -Be 'Azure/terraform-azure-avm-res-module-101'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 2
    }

    It 'handles an empty installation without requesting extra pages' {
        $script:terraformRoutingInstallationPages[1] = [pscustomobject]@{ total_count = 0; repositories = @() }
        @(Get-RepositoryInstalledRepositories) | Should -HaveCount 0
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1
    }

    It 'rejects incomplete pages and totals that change during discovery' {
        $script:terraformRoutingInstallationPages[2].repositories = @()
        { Get-RepositoryInstalledRepositories } | Should -Throw '*incomplete app repository list*'
        $script:terraformRoutingInstallationPages[2].total_count = 102
        { Get-RepositoryInstalledRepositories } | Should -Throw '*changed during pagination*'
    }

    It 'rejects sparse or duplicate repository lists rather than broadening the token' {
        $item = New-InstalledRoutingRepository -Number 1
        $script:terraformRoutingInstallationPages[1] = [pscustomobject]@{ total_count = 2; repositories = @($item) }
        { Get-RepositoryInstalledRepositories } | Should -Throw '*count does not match*'
        $script:terraformRoutingInstallationPages[1].repositories = @($item, $item)
        { Get-RepositoryInstalledRepositories } | Should -Throw '*duplicate installed repository*'
    }

    It 'surfaces API errors without returning a partial installed scope' {
        Mock Invoke-RepositorySyncProcess {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'installation denied' }
        }
        { Get-RepositoryInstalledRepositories } | Should -Throw '*Cannot list*installation denied*'
    }
}

Describe 'Terraform reviewer routing catalog and metadata' {
    BeforeEach {
        $script:terraformRoutingCatalog = @{
            modules = @{
                'Microsoft.Storage/storageAccounts' = @{
                    bicep = @(@{ repository = 'Azure/bicep-registry-modules'; modulePath = 'avm/res/storage/storage-account'; owners = @() })
                    terraform = @(
                        @{ repository = $script:terraformRoutingRepository; modulePath = '.'; owners = @(@{ handle = 'root-owner'; type = 'user' }) }
                        @{ repository = $script:terraformRoutingRepository; modulePath = 'modules/child'; owners = @(@{ handle = 'child-owner'; type = 'user' }) }
                        @{ repository = $script:secondTerraformRoutingRepository; modulePath = '.'; owners = @(@{ handle = 'other-owner'; type = 'user' }) }
                    )
                }
            }
        }
        Mock Get-AvmRepositoryFileAtRef {
            [pscustomobject]@{ Content = ($script:terraformRoutingCatalog | ConvertTo-Json -Depth 15) }
        }
    }

    It 'selects only the requested repository and ecosystem from a shared catalog' {
        $index = Get-AvmReviewerRoutingCatalogIndex -Repository $script:terraformRoutingRepository `
            -Ecosystem terraform -Catalog $script:terraformRoutingCatalog
        $index.Count | Should -Be 2
        $index['.'].owners[0].handle | Should -Be 'root-owner'
        $index['modules/child'].owners[0].handle | Should -Be 'child-owner'
        Should -Invoke Get-AvmRepositoryFileAtRef -Exactly 0
    }

    It 'preserves Bicep indexing as the default ecosystem' {
        $index = Get-AvmReviewerRoutingCatalogIndex -Repository 'Azure/bicep-registry-modules'
        $index.Keys | Should -Be @('avm/res/storage/storage-account')
        Should -Invoke Get-AvmRepositoryFileAtRef -Exactly 1 -ParameterFilter {
            $Repository -eq 'Azure/Azure-Verified-Modules' -and $Path -eq 'docs/static/module-indexes/v1/modules.json' -and $Ref -eq 'main'
        }
    }

    It 'rejects a published document without the modules map' {
        Mock Get-AvmRepositoryFileAtRef { [pscustomobject]@{ Content = '{}' } }
        { Get-AvmReviewerRoutingCatalog } | Should -Throw '*modules map*'
    }

    It 'reads root metadata at the request head when the root is absent from the catalog' {
        Mock Get-AvmRepositoryFileAtRef { [pscustomobject]@{ Content = '{"owners":["new-owner","@Azure/storage-owners"]}' } }
        $owners = @(Get-AvmModuleOwners -TopLevelModulePath '.' -CatalogIndex @{} `
            -Repository $script:terraformRoutingRepository -Ref 'deadbeef')
        $owners.Handle | Should -Be @('new-owner', 'Azure/storage-owners')
        $owners.Type | Should -Be @('user', 'team')
        Should -Invoke Get-AvmRepositoryFileAtRef -Exactly 1 -ParameterFilter {
            $Path -eq 'metadata.json' -and $Repository -eq $script:terraformRoutingRepository -and $Ref -eq 'deadbeef' -and $AllowMissing
        }
    }

    It 'returns no owners for an absent root without fetching child metadata' {
        Mock Get-AvmRepositoryFileAtRef { $null }
        @(Get-AvmModuleOwners -TopLevelModulePath '.' -CatalogIndex @{} `
            -Repository $script:terraformRoutingRepository -Ref 'deadbeef') | Should -HaveCount 0
        Should -Invoke Get-AvmRepositoryFileAtRef -Exactly 1 -ParameterFilter { $Path -eq 'metadata.json' }
    }

    It 'does not treat invalid metadata or a failed file read as an orphan' {
        Mock Get-AvmRepositoryFileAtRef { [pscustomobject]@{ Content = '{"owners":["not a handle"]}' } }
        { Get-AvmModuleOwners -TopLevelModulePath '.' -CatalogIndex @{} `
            -Repository $script:terraformRoutingRepository -Ref 'deadbeef' } | Should -Throw '*Invalid owner handle*'
        Mock Get-AvmRepositoryFileAtRef { throw [System.InvalidOperationException]::new('metadata read failed') }
        { Get-AvmModuleOwners -TopLevelModulePath '.' -CatalogIndex @{} `
            -Repository $script:terraformRoutingRepository -Ref 'deadbeef' } | Should -Throw '*metadata read failed*'
    }
}

Describe 'Terraform reviewer routing decisions' {
    BeforeEach {
        $script:terraformRoutingPr = New-TerraformRoutingPullRequest
        $script:terraformRoutingIndex = @{
            '.' = @{ owners = @(@{ handle = 'root-owner'; type = 'user' }) }
            'modules/child' = @{ owners = @(@{ handle = 'child-owner'; type = 'user' }) }
        }
        Mock Get-AvmRepositoryFileAtRef { throw 'Unexpected metadata lookup.' }
        Mock Get-AvmPrReviewerRoutingChangedFiles { @('main.tf') }
        Mock Invoke-RepositoryGitHub { $null }
    }

    It 'routes root, example, child, and repository files to root owners' -ForEach @(
        @{ ChangedPath = 'main.tf' }
        @{ ChangedPath = 'examples/default/main.tf' }
        @{ ChangedPath = 'modules/child/main.tf' }
        @{ ChangedPath = 'modules/child/metadata.json' }
        @{ ChangedPath = '.github/workflows/terraform.yml' }
    ) {
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:terraformRoutingPr `
            -Repository $script:terraformRoutingRepository -CatalogIndex $script:terraformRoutingIndex `
            -ChangedFilePaths @($ChangedPath) -Ecosystem terraform
        $routing.NewReviewers | Should -Be @('root-owner')
        $routing.NewLabels | Should -Be @('Needs: Module Owner :mega:')
        $routing.Modules.ModulePath | Should -Be @('.')
        $routing.Modules.Source | Should -Be @('catalog')
        Should -Invoke Get-AvmRepositoryFileAtRef -Exactly 0
    }

    It 'uses changed root metadata instead of stale catalog owners' {
        Mock Get-AvmRepositoryFileAtRef { [pscustomobject]@{ Content = '{"owners":["fresh-owner"]}' } }
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:terraformRoutingPr `
            -Repository $script:terraformRoutingRepository -CatalogIndex $script:terraformRoutingIndex `
            -ChangedFilePaths @('metadata.json', 'main.tf') -Ecosystem terraform
        $routing.NewReviewers | Should -Be @('fresh-owner')
        $routing.Modules.Source | Should -Be @('metadata.json')
        Should -Invoke Get-AvmRepositoryFileAtRef -Exactly 1 -ParameterFilter {
            $Path -eq 'metadata.json' -and $Ref -eq $script:terraformRoutingPr.headRefOid
        }
    }

    It 'uses the shared orphan team and labels for an explicitly unowned root' {
        $script:terraformRoutingIndex['.'].owners = @()
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:terraformRoutingPr `
            -Repository $script:terraformRoutingRepository -CatalogIndex $script:terraformRoutingIndex `
            -ChangedFilePaths @('main.tf') -Ecosystem terraform
        $routing.NewReviewers | Should -Be @('Azure/azure-verified-modules-module-owners')
        $routing.NewLabels | Should -Contain 'Needs: Core Team :genie:'
        $routing.NewLabels | Should -Contain 'Status: Module Orphaned :yellow_circle:'
        $routing.OrphanedModules | Should -Be @('.')
    }

    It 'preserves core-team handling for protected test files' {
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:terraformRoutingPr `
            -Repository $script:terraformRoutingRepository -CatalogIndex $script:terraformRoutingIndex `
            -ChangedFilePaths @('tests/e2e/.e2eignore') -Ecosystem terraform
        $routing.NewReviewers | Should -Be @('root-owner')
        $routing.NewLabels | Should -Contain 'Needs: Core Team :genie:'
        $routing.CoreTeamPaths | Should -Be @('tests/e2e/.e2eignore')
    }

    It 'skips authors, requested users and teams, and existing reviewers without orphaning the module' {
        $script:terraformRoutingIndex['.'].owners = @(
            @{ handle = 'contributor'; type = 'user' }
            @{ handle = 'requested-owner'; type = 'user' }
            @{ handle = 'reviewed-owner'; type = 'user' }
            @{ handle = '@Azure/storage-owners'; type = 'team' }
        )
        $script:terraformRoutingPr.reviewRequests = @(
            [pscustomobject]@{ login = 'requested-owner' }
            [pscustomobject]@{ slug = 'storage-owners' }
        )
        $script:terraformRoutingPr.reviews = @([pscustomobject]@{ author = [pscustomobject]@{ login = 'reviewed-owner' } })
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:terraformRoutingPr `
            -Repository $script:terraformRoutingRepository -CatalogIndex $script:terraformRoutingIndex `
            -ChangedFilePaths @('main.tf') -Ecosystem terraform
        $routing.NewReviewers | Should -HaveCount 0
        $routing.SkippedReviewers | Should -HaveCount 4
        $routing.OrphanedModules | Should -HaveCount 0
        $routing.NewLabels | Should -Not -Contain 'Status: Module Orphaned :yellow_circle:'
    }

    It 'plans writes under WhatIf and is a no-op once routing is present' {
        $outcome = Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:terraformRoutingPr `
            -Repository $script:terraformRoutingRepository -CatalogIndex $script:terraformRoutingIndex -Ecosystem terraform -WhatIf
        $outcome.Status | Should -Be 'WouldUpdate'
        $outcome.NewReviewers | Should -Be @('root-owner')
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0

        $script:terraformRoutingPr.reviewRequests = @([pscustomobject]@{ login = 'root-owner' })
        $script:terraformRoutingPr.labels = @([pscustomobject]@{ name = 'Needs: Module Owner :mega:' })
        $outcome = Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:terraformRoutingPr `
            -Repository $script:terraformRoutingRepository -CatalogIndex $script:terraformRoutingIndex -Ecosystem terraform
        $outcome.Status | Should -Be 'AlreadyRouted'
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'does not read files or write reviewers for drafts or requests closed after discovery' -ForEach @(
        @{ RequestState = 'OPEN'; IsDraft = $true; ExpectedStatus = 'Draft' }
        @{ RequestState = 'CLOSED'; IsDraft = $false; ExpectedStatus = 'Closed' }
        @{ RequestState = 'MERGED'; IsDraft = $false; ExpectedStatus = 'Closed' }
    ) {
        $script:terraformRoutingPr.state = $RequestState
        $script:terraformRoutingPr.isDraft = $IsDraft
        $outcome = Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:terraformRoutingPr `
            -Repository $script:terraformRoutingRepository -CatalogIndex $script:terraformRoutingIndex -Ecosystem terraform
        $outcome.Status | Should -Be $ExpectedStatus
        Should -Invoke Get-AvmPrReviewerRoutingChangedFiles -Exactly 0
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'refreshes ownership when a rename removes root metadata' {
        Mock Get-AvmPrReviewerRoutingChangedFiles {
            @('metadata.old.json', 'metadata.json')
        }
        Mock Get-AvmRepositoryFileAtRef { $null }
        $outcome = Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:terraformRoutingPr `
            -Repository $script:terraformRoutingRepository -CatalogIndex $script:terraformRoutingIndex -Ecosystem terraform -WhatIf
        $outcome.NewReviewers | Should -Be @('Azure/azure-verified-modules-module-owners')
        $outcome.NewLabels | Should -Contain 'Status: Module Orphaned :yellow_circle:'
        Should -Invoke Get-AvmRepositoryFileAtRef -Exactly 1 -ParameterFilter { $Path -eq 'metadata.json' }
    }
}

Describe 'Terraform reviewer routing installed targets' {
    BeforeEach {
        $script:terraformRoutingInstalled = @(
            [pscustomobject]@{ name = 'bicep-registry-modules'; full_name = 'Azure/bicep-registry-modules'; archived = $false }
            [pscustomobject]@{ name = 'terraform-azure-avm-res-storage-storageaccount'; full_name = $script:terraformRoutingRepository; archived = $false }
            [pscustomobject]@{ name = 'terraform-azurerm-avm-res-keyvault-vault'; full_name = $script:secondTerraformRoutingRepository; archived = $false }
            [pscustomobject]@{ name = 'terraform-azapi-avm-utl-example'; full_name = 'Azure/terraform-azapi-avm-utl-example'; archived = $false }
            [pscustomobject]@{ name = 'terraform-azure-avm-ptn-archived'; full_name = 'Azure/terraform-azure-avm-ptn-archived'; archived = $true }
            [pscustomobject]@{ name = 'terraform-azurerm-avm-template'; full_name = 'Azure/terraform-azurerm-avm-template'; archived = $false }
            [pscustomobject]@{ name = 'azure-verified-modules-tools'; full_name = 'Azure/azure-verified-modules-tools'; archived = $false }
            [pscustomobject]@{ name = 'terraform-azure-avm-res-other'; full_name = 'Other/terraform-azure-avm-res-other'; archived = $false }
        )
        Mock Get-RepositoryInstalledRepositories { $script:terraformRoutingInstalled }
    }

    It 'includes only active installed Bicep and supported Terraform modules' {
        $repositories = @(Get-AvmPrReviewerRoutingRepositories)
        $repositories | Should -HaveCount 4
        $repositories | Should -Contain 'Azure/bicep-registry-modules'
        $repositories | Should -Contain $script:terraformRoutingRepository
        $repositories | Should -Contain $script:secondTerraformRoutingRepository
        $repositories | Should -Contain 'Azure/terraform-azapi-avm-utl-example'
    }

    It 'keeps a bare number scoped to Bicep and a full or API URL scoped to Terraform' {
        @(Get-AvmPrReviewerRoutingRepositories -PullRequestUrl '42') | Should -Be @('Azure/bicep-registry-modules')
        @(Get-AvmPrReviewerRoutingRepositories -PullRequestUrl "https://github.com/$script:terraformRoutingRepository/pull/42") |
            Should -Be @($script:terraformRoutingRepository)
        @(Get-AvmPrReviewerRoutingRepositories -PullRequestUrl "https://api.github.com/repos/$script:terraformRoutingRepository/pulls/42") |
            Should -Be @($script:terraformRoutingRepository)
    }

    It 'rejects archived, unrelated, and uninstalled URL targets' -ForEach @(
        @{ TargetRepository = 'Azure/terraform-azure-avm-ptn-archived' }
        @{ TargetRepository = 'Azure/azure-verified-modules-tools' }
        @{ TargetRepository = 'Azure/terraform-azure-avm-res-uninstalled' }
        @{ TargetRepository = 'Other/terraform-azure-avm-res-other' }
    ) {
        { Get-AvmPrReviewerRoutingRepositories -PullRequestUrl "https://github.com/$TargetRepository/pull/42" } |
            Should -Throw '*not an active AVM repository*'
    }

    It 'rejects malformed targets without granting an unrestricted scope' -ForEach @(
        @{ InvalidTarget = '0' }
        @{ InvalidTarget = '-1' }
        @{ InvalidTarget = 'https://example.com/Azure/bicep-registry-modules/pull/42' }
        @{ InvalidTarget = 'https://github.com/Azure/bicep-registry-modules/issues/42' }
    ) {
        { Get-AvmPrReviewerRoutingRepositories -PullRequestUrl $InvalidTarget } | Should -Throw '*pull request URL*'
    }

    It 'fails explicitly when installation discovery fails or returns no targets' {
        Mock Get-RepositoryInstalledRepositories { throw [System.InvalidOperationException]::new('installation failed') }
        { Get-AvmPrReviewerRoutingRepositories } | Should -Throw '*installation failed*'
        Mock Get-RepositoryInstalledRepositories { @() }
        { Get-AvmPrReviewerRoutingRepositories } | Should -Throw '*No active AVM*'
    }
}

Describe 'Terraform reviewer routing search pagination' {
    BeforeEach {
        $script:terraformRoutingSearchResponse = [pscustomobject]@{ total_count = 0; incomplete_results = $false; items = @() }
        Mock Invoke-RepositoryGitHub { $script:terraformRoutingSearchResponse }
    }

    It 'batches exact repository qualifiers and a server-side ready-request lookback' {
        $repositories = @(1..21 | ForEach-Object { "Azure/terraform-azure-avm-res-module-$_" })
        @(Get-AvmPrReviewerRoutingSearchCandidates -Repositories $repositories -UpdatedWithinMinutes 60) | Should -HaveCount 0
        Should -Invoke Invoke-RepositoryGitHub -Exactly 2
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter {
            $query = @($Arguments | Where-Object { $_ -like 'q=*' })[0]
            $query -match 'is:pr is:open draft:false archived:false updated:>=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z ' -and
            $query -like '*repo:Azure/terraform-azure-avm-res-module-20' -and
            $query -notlike '*repo:Azure/terraform-azure-avm-res-module-21*' -and
            $Arguments -contains 'per_page=100' -and $Arguments -contains 'sort=created' -and $Arguments -contains 'order=asc'
        }
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter {
            $query = @($Arguments | Where-Object { $_ -like 'q=*' })[0]
            $query -like '*repo:Azure/terraform-azure-avm-res-module-21' -and
            $query -notlike '*repo:Azure/terraform-azure-avm-res-module-20*'
        }
    }

    It 'returns request stubs for all pages without querying empty repositories individually' {
        Mock Invoke-RepositoryGitHub {
            param($Arguments)
            $items = if ($Arguments -contains 'page=2') {
                @(New-TerraformRoutingSearchItem -Number 101)
            } else {
                @(1..100 | ForEach-Object { New-TerraformRoutingSearchItem -Number $_ })
            }
            [pscustomobject]@{ total_count = 101; incomplete_results = $false; items = $items }
        }
        $candidates = @(Get-AvmPrReviewerRoutingSearchCandidates -Repositories @($script:terraformRoutingRepository) -UpdatedWithinMinutes 60)
        $candidates | Should -HaveCount 101
        $candidates[-1].number | Should -Be 101
        $candidates[-1].Repository | Should -Be $script:terraformRoutingRepository
        Should -Invoke Invoke-RepositoryGitHub -Exactly 2
    }

    It 'retrieves exactly 1000 results instead of treating the cap boundary as truncation' {
        Mock Invoke-RepositoryGitHub {
            param($Arguments)
            $pageArgument = @($Arguments | Where-Object { $_ -like 'page=*' })[0]
            $page = [int]$pageArgument.Substring(5)
            $start = (($page - 1) * 100) + 1
            $items = @($start..($start + 99) | ForEach-Object { New-TerraformRoutingSearchItem -Number $_ })
            [pscustomobject]@{ total_count = 1000; incomplete_results = $false; items = $items }
        }
        @(Get-AvmPrReviewerRoutingSearchCandidates -Repositories @($script:terraformRoutingRepository) -UpdatedWithinMinutes 60) |
            Should -HaveCount 1000
        Should -Invoke Invoke-RepositoryGitHub -Exactly 10
    }

    It 'rejects incomplete and over-cap responses' -ForEach @(
        @{ Total = 1; Incomplete = $true }
        @{ Total = 1001; Incomplete = $false }
    ) {
        $script:terraformRoutingSearchResponse.total_count = $Total
        $script:terraformRoutingSearchResponse.incomplete_results = $Incomplete
        { Get-AvmPrReviewerRoutingSearchCandidates -Repositories @($script:terraformRoutingRepository) -UpdatedWithinMinutes 60 } |
            Should -Throw '*incomplete results*'
    }

    It 'rejects duplicate and out-of-scope results rather than routing a partial set' {
        $item = New-TerraformRoutingSearchItem
        $script:terraformRoutingSearchResponse = [pscustomobject]@{ total_count = 2; incomplete_results = $false; items = @($item, $item) }
        { Get-AvmPrReviewerRoutingSearchCandidates -Repositories @($script:terraformRoutingRepository) -UpdatedWithinMinutes 60 } |
            Should -Throw '*unexpected or duplicate*'
        $script:terraformRoutingSearchResponse = [pscustomobject]@{
            total_count = 1; incomplete_results = $false
            items = @((New-TerraformRoutingSearchItem -Repository 'Other/unrelated'))
        }
        { Get-AvmPrReviewerRoutingSearchCandidates -Repositories @($script:terraformRoutingRepository) -UpdatedWithinMinutes 60 } |
            Should -Throw '*unexpected or duplicate*'
    }

    It 'rejects prematurely empty pages and pagination totals that change' {
        $script:terraformRoutingSearchResponse.total_count = 1
        { Get-AvmPrReviewerRoutingSearchCandidates -Repositories @($script:terraformRoutingRepository) -UpdatedWithinMinutes 60 } |
            Should -Throw '*before all results*'
        Mock Invoke-RepositoryGitHub {
            param($Arguments)
            $total = if ($Arguments -contains 'page=2') { 102 } else { 101 }
            [pscustomobject]@{ total_count = $total; incomplete_results = $false; items = @((New-TerraformRoutingSearchItem)) }
        }
        { Get-AvmPrReviewerRoutingSearchCandidates -Repositories @($script:terraformRoutingRepository) -UpdatedWithinMinutes 60 } |
            Should -Throw '*changed during pagination*'
    }
}

Describe 'Terraform reviewer routing fleet sweep' {
    BeforeEach {
        $script:terraformRoutingSearchCandidate = [pscustomobject]@{
            Repository = $script:terraformRoutingRepository
            number = 1
            url = "https://github.com/$script:terraformRoutingRepository/pull/1"
        }
        Mock Get-AvmReviewerRoutingCatalog { @{ modules = @{} } }
        Mock Get-AvmPrReviewerRoutingSearchCandidates { @($script:terraformRoutingSearchCandidate) }
        Mock Invoke-AvmPrReviewerRouting { }
        Mock Write-AvmRunSummary { }
    }

    It 'reads the catalog once and queries only repositories with search candidates while retaining Bicep' {
        Invoke-AvmPrReviewerRoutingSweep -Repository @(
            'Azure/bicep-registry-modules', $script:terraformRoutingRepository, $script:secondTerraformRoutingRepository
        ) -UpdatedWithinMinutes 60 -WhatIf
        Should -Invoke Get-AvmReviewerRoutingCatalog -Exactly 1
        Should -Invoke Get-AvmPrReviewerRoutingSearchCandidates -Exactly 1 -ParameterFilter { $Repositories.Count -eq 2 }
        Should -Invoke Invoke-AvmPrReviewerRouting -Exactly 2
        Should -Invoke Invoke-AvmPrReviewerRouting -Exactly 1 -ParameterFilter {
            $Repository -eq $script:terraformRoutingRepository -and $Ecosystem -eq 'terraform' -and $WhatIf -and $PullRequests.Count -eq 1
        }
        Should -Invoke Invoke-AvmPrReviewerRouting -Exactly 1 -ParameterFilter {
            $Repository -eq 'Azure/bicep-registry-modules' -and $Ecosystem -eq 'bicep' -and $WhatIf
        }
    }

    It 'uses complete per-repository lists for the daily or manual zero-minute sweep' {
        Invoke-AvmPrReviewerRoutingSweep -Repository @($script:terraformRoutingRepository, $script:secondTerraformRoutingRepository)
        Should -Invoke Get-AvmPrReviewerRoutingSearchCandidates -Exactly 0
        Should -Invoke Invoke-AvmPrReviewerRouting -Exactly 2 -ParameterFilter { $null -eq $PullRequests }
    }

    It 'falls back to each repository after a search error and logs the reason' {
        Mock Get-AvmPrReviewerRoutingSearchCandidates { throw [System.InvalidOperationException]::new('incomplete search') }
        $output = @(Invoke-AvmPrReviewerRoutingSweep `
            -Repository @($script:terraformRoutingRepository, $script:secondTerraformRoutingRepository) -UpdatedWithinMinutes 60 3>&1)
        @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) -join "`n" |
            Should -Match 'incomplete search.*Falling back'
        Should -Invoke Invoke-AvmPrReviewerRouting -Exactly 2 -ParameterFilter { $null -eq $PullRequests }
    }

    It 'continues after a repository fails and reports an aggregate failure' {
        Mock Invoke-AvmPrReviewerRouting {
            param($Repository)
            if ($Repository -eq $script:terraformRoutingRepository) {
                throw [System.InvalidOperationException]::new('repository failed')
            }
        }
        { Invoke-AvmPrReviewerRoutingSweep -Repository @(
            'Azure/bicep-registry-modules', $script:terraformRoutingRepository, $script:secondTerraformRoutingRepository
        ) 3>$null } | Should -Throw '*repository failed*'
        Should -Invoke Invoke-AvmPrReviewerRouting -Exactly 3
        Should -Invoke Write-AvmRunSummary -Exactly 1 -ParameterFilter { $Failures.Count -eq 1 }
    }

    It 'routes an explicit API URL only in its selected repository without a search' {
        Invoke-AvmPrReviewerRoutingSweep -Repository @('Azure/bicep-registry-modules', $script:terraformRoutingRepository) `
            -PullRequestUrl "https://api.github.com/repos/$script:terraformRoutingRepository/pulls/42" -UpdatedWithinMinutes 60
        Should -Invoke Invoke-AvmPrReviewerRouting -Exactly 1 -ParameterFilter {
            $Repository -eq $script:terraformRoutingRepository -and $PullRequestUrl -eq "https://github.com/$script:terraformRoutingRepository/pull/42"
        }
        Should -Invoke Get-AvmPrReviewerRoutingSearchCandidates -Exactly 0
    }

    It 'preserves Bicep bare-number selection and rejects URLs outside the selected fleet' {
        Invoke-AvmPrReviewerRoutingSweep -Repository @('Azure/bicep-registry-modules', $script:terraformRoutingRepository) -PullRequestUrl '42'
        Should -Invoke Invoke-AvmPrReviewerRouting -Exactly 1 -ParameterFilter {
            $Repository -eq 'Azure/bicep-registry-modules' -and $PullRequestUrl -eq 'https://github.com/Azure/bicep-registry-modules/pull/42'
        }
        { Invoke-AvmPrReviewerRoutingSweep -Repository @($script:terraformRoutingRepository) `
            -PullRequestUrl 'https://github.com/Other/unrelated/pull/42' } | Should -Throw '*outside the requested*'
        Should -Invoke Get-AvmReviewerRoutingCatalog -Exactly 1
    }
}

Describe 'Terraform reviewer routing candidate hydration' {
    BeforeEach {
        $script:terraformRoutingPr = New-TerraformRoutingPullRequest
        $script:terraformRoutingIndex = @{ '.' = @{ owners = @(@{ handle = 'root-owner'; type = 'user' }) } }
        $script:terraformRoutingStub = [pscustomobject]@{ number = 1; url = $script:terraformRoutingPr.url }
        Mock Get-AvmPrReviewerRoutingCandidates { @($script:terraformRoutingPr) }
        Mock Get-AvmPrReviewerRoutingChangedFiles { @('main.tf') }
        Mock Invoke-RepositoryGitHub { $null }
        Mock Write-AvmPrReviewerRoutingSummary { }
    }

    It 'retrieves current review state at each discovered URL before applying Terraform rules' {
        Invoke-AvmPrReviewerRouting -Repository $script:terraformRoutingRepository -Ecosystem terraform `
            -CatalogIndex $script:terraformRoutingIndex -PullRequests @($script:terraformRoutingStub)
        Should -Invoke Get-AvmPrReviewerRoutingCandidates -Exactly 1 -ParameterFilter { $PullRequestUrl -eq $script:terraformRoutingPr.url }
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter {
            $Arguments -contains 'edit' -and $Arguments -contains 'root-owner'
        }
    }

    It 'skips a discovered request that became a draft before its details were read' {
        $script:terraformRoutingPr.isDraft = $true
        Invoke-AvmPrReviewerRouting -Repository $script:terraformRoutingRepository -Ecosystem terraform `
            -CatalogIndex $script:terraformRoutingIndex -PullRequests @($script:terraformRoutingStub)
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
        Should -Invoke Get-AvmPrReviewerRoutingChangedFiles -Exactly 0
    }

    It 'continues with remaining requests when one detail fetch fails' {
        $script:terraformRoutingPr = New-TerraformRoutingPullRequest -Number 2
        Mock Get-AvmPrReviewerRoutingCandidates {
            param($PullRequestUrl)
            if ($PullRequestUrl -like '*/pull/1') { throw [System.InvalidOperationException]::new('request details failed') }
            @($script:terraformRoutingPr)
        }
        { Invoke-AvmPrReviewerRouting -Repository $script:terraformRoutingRepository -Ecosystem terraform `
            -CatalogIndex $script:terraformRoutingIndex `
            -PullRequests @($script:terraformRoutingStub, [pscustomobject]@{ number = 2; url = $script:terraformRoutingPr.url }) 3>$null } |
            Should -Throw '*request details failed*'
        Should -Invoke Get-AvmPrReviewerRoutingCandidates -Exactly 2
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter { $Arguments -contains 'edit' }
        Should -Invoke Write-AvmPrReviewerRoutingSummary -Exactly 1 -ParameterFilter { $Failures.Count -eq 1 -and $Outcomes.Count -eq 1 }
    }
}

Describe 'Terraform reviewer routing missing-label fleet warnings' {
    BeforeEach {
        $script:terraformMissingLabelPr = New-TerraformRoutingPullRequest
        $script:terraformReadyPr = New-TerraformRoutingPullRequest -Number 2
        $script:terraformReadyPr.url = "https://github.com/$script:secondTerraformRoutingRepository/pull/2"
        Mock Get-AvmReviewerRoutingCatalog {
            @{
                modules = @{
                    'Microsoft.Storage/storageAccounts' = @{
                        terraform = @(
                            @{ repository = $script:terraformRoutingRepository; modulePath = '.'; owners = @(@{ handle = 'root-owner'; type = 'user' }) }
                            @{ repository = $script:secondTerraformRoutingRepository; modulePath = '.'; owners = @(@{ handle = 'root-owner'; type = 'user' }) }
                        )
                    }
                }
            }
        }
        Mock Get-AvmPrReviewerRoutingCandidates {
            param($Repository)
            if ($Repository -eq $script:terraformRoutingRepository) {
                return @($script:terraformMissingLabelPr)
            }
            return @($script:terraformReadyPr)
        }
        Mock Get-AvmPrReviewerRoutingChangedFiles { @('main.tf') }
        Mock Write-AvmRunSummary { }
        Mock Invoke-RepositoryGitHub {
            if ($Arguments[2] -eq $script:terraformMissingLabelPr.url) {
                throw [System.InvalidOperationException]::new("GitHub operation failed: 'Needs: Module Owner :mega:' not found")
            }
        }
    }

    It 'does not fail the fleet for a missing label and still routes the other repository' {
        Invoke-AvmPrReviewerRoutingSweep `
            -Repository @($script:terraformRoutingRepository, $script:secondTerraformRoutingRepository) 3>$null 6>$null
        Should -Invoke Invoke-RepositoryGitHub -Exactly 2 -ParameterFilter { $Arguments -contains 'edit' }
        Should -Invoke Write-AvmRunSummary -Exactly 1 -ParameterFilter {
            $Title -eq 'Reviewer routing fleet' -and $Failures.Count -eq 0
        }
        Should -Invoke Write-AvmRunSummary -Exactly 1 -ParameterFilter {
            $Title -eq 'Pull request reviewer routing' -and $Warnings.Count -eq 1 -and $Failures.Count -eq 0
        }
    }

    It 'preserves a real GraphQL failure alongside a missing-label warning' {
        Mock Invoke-RepositoryGitHub {
            if ($Arguments[2] -eq $script:terraformMissingLabelPr.url) {
                throw [System.InvalidOperationException]::new("GitHub operation failed: 'Needs: Module Owner :mega:' not found")
            }
            throw [System.InvalidOperationException]::new('GitHub operation failed: GraphQL: Something went wrong while executing your query')
        }
        { Invoke-AvmPrReviewerRoutingSweep `
            -Repository @($script:terraformRoutingRepository, $script:secondTerraformRoutingRepository) 3>$null 6>$null } |
            Should -Throw '*GraphQL*'
        Should -Invoke Write-AvmRunSummary -Exactly 1 -ParameterFilter {
            $Title -eq 'Reviewer routing fleet' -and $Failures.Count -eq 1 -and $Failures[0] -notlike '*not found*'
        }
    }

    It 'preserves WhatIf without attempting a missing-label edit or creating labels' {
        Invoke-AvmPrReviewerRoutingSweep `
            -Repository @($script:terraformRoutingRepository, $script:secondTerraformRoutingRepository) -WhatIf 6>$null
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
        Should -Invoke Write-AvmRunSummary -Exactly 1 -ParameterFilter {
            $Title -eq 'Reviewer routing fleet' -and $DryRun -and $Failures.Count -eq 0
        }
    }
}
