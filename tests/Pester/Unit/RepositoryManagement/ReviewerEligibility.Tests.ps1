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
    . (Join-Path $lib 'PrReviewerRoutingEligibility.ps1')
    . (Join-Path $lib 'PrReviewerRouting.ps1')
    . (Join-Path $lib 'PrReviewerRoutingDiscovery.ps1')
    Set-StrictMode -Version 3.0

    $script:eligibilityRepository = 'Azure/terraform-azure-avm-res-storage-storageaccount'
    $script:ownersGroup = 'Azure/azure-verified-modules-module-owners'

    function New-EligibilityPullRequest {
        param([int] $Number = 1)
        [pscustomobject]@{
            number = $Number
            url = "https://github.com/$script:eligibilityRepository/pull/$Number"
            author = [pscustomobject]@{ login = 'contributor' }
            isDraft = $false
            state = 'OPEN'
            reviewRequests = @()
            reviews = @()
            labels = @()
            headRefOid = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
        }
    }

    function New-EligibilityOwner {
        param([string] $Handle, [string] $Type = 'user')
        @{ handle = $Handle; type = $Type; displayName = $null }
    }
}

Describe 'Get-AvmPrReviewerRoutingEligibility' {
    BeforeEach {
        $script:eligibilityResponse = [pscustomobject]@{
            permission = 'write'
            user = [pscustomobject]@{ login = 'owner' }
        }
        Mock Invoke-RepositoryGitHub { $script:eligibilityResponse }
    }

    It 'requires effective repository write access for a user: <Permission>' -TestCases @(
        @{ Permission = 'none'; Eligible = $false }
        @{ Permission = 'read'; Eligible = $false }
        @{ Permission = 'triage'; Eligible = $false }
        @{ Permission = 'triage_plus'; Eligible = $false }
        @{ Permission = 'write'; Eligible = $true }
        @{ Permission = 'maintain'; Eligible = $true }
        @{ Permission = 'admin'; Eligible = $true }
    ) {
        param($Permission, $Eligible)
        $script:eligibilityResponse.permission = $Permission
        $result = Get-AvmPrReviewerRoutingEligibility -Repository $script:eligibilityRepository -Handle owner -Type user
        $result.Eligible | Should -Be $Eligible
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter {
            $AsJson -and $Arguments -contains 'GET' -and
            $Arguments -contains "repos/$script:eligibilityRepository/collaborators/owner/permission"
        }
    }

    It 'reads team-specific permissions rather than the token actor''s repository permission' {
        $script:eligibilityResponse = [pscustomobject]@{
            full_name = $script:eligibilityRepository
            permissions = [pscustomobject]@{ push = $true }
        }
        $result = Get-AvmPrReviewerRoutingEligibility -Repository $script:eligibilityRepository -Handle $script:ownersGroup -Type team
        $result.Eligible | Should -BeTrue
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter {
            $Arguments -contains 'Accept: application/vnd.github.v3.repository+json' -and
            $Arguments -contains "orgs/Azure/teams/azure-verified-modules-module-owners/repos/$script:eligibilityRepository" -and
            $Arguments -contains 'GET'
        }
        $script:eligibilityResponse.permissions.push = $false
        (Get-AvmPrReviewerRoutingEligibility -Repository $script:eligibilityRepository -Handle $script:ownersGroup -Type team).Eligible |
            Should -BeFalse
    }

    It 'does not attempt a cross-organization team lookup' {
        $result = Get-AvmPrReviewerRoutingEligibility -Repository $script:eligibilityRepository -Handle 'Other/owners' -Type team
        $result.Eligible | Should -BeFalse
        $result.Reason | Should -Match 'does not belong'
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'caches confirmed permission results case-insensitively and only for the same repository' {
        $cache = @{}
        $null = Get-AvmPrReviewerRoutingEligibility -Repository $script:eligibilityRepository -Handle owner -Type user -Cache $cache
        $null = Get-AvmPrReviewerRoutingEligibility -Repository $script:eligibilityRepository.ToUpperInvariant() -Handle OWNER -Type user -Cache $cache
        $null = Get-AvmPrReviewerRoutingEligibility -Repository 'Azure/terraform-azure-avm-res-other' -Handle owner -Type user -Cache $cache
        $cache.Count | Should -Be 2
        Should -Invoke Invoke-RepositoryGitHub -Exactly 2
    }

    It 'treats a confirmed not-found response as ineligible and caches it' {
        Mock Invoke-RepositoryGitHub { throw [System.InvalidOperationException]::new('GitHub operation failed: gh: Not Found (HTTP 404)') }
        $cache = @{}
        (Get-AvmPrReviewerRoutingEligibility -Repository $script:eligibilityRepository -Handle owner -Type user -Cache $cache).Eligible |
            Should -BeFalse
        $null = Get-AvmPrReviewerRoutingEligibility -Repository $script:eligibilityRepository -Handle owner -Type user -Cache $cache
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1
    }

    It 'does not downgrade or cache failed permission lookups: <Failure>' -TestCases @(
        @{ Failure = 'gh: Forbidden (HTTP 403)' }
        @{ Failure = 'gh: rate limited (HTTP 429)' }
        @{ Failure = 'gh: server error (HTTP 500)' }
        @{ Failure = 'connection failed' }
    ) {
        param($Failure)
        $script:permissionFailure = $Failure
        Mock Invoke-RepositoryGitHub { throw [System.InvalidOperationException]::new($script:permissionFailure) }
        $cache = @{}
        { Get-AvmPrReviewerRoutingEligibility -Repository $script:eligibilityRepository -Handle owner -Type user -Cache $cache } |
            Should -Throw
        $cache.Count | Should -Be 0
    }

    It 'rejects unknown, substituted, or incomplete user permission responses' -TestCases @(
        @{ Response = $null }
        @{ Response = [pscustomobject]@{ permission = 'custom'; user = [pscustomobject]@{ login = 'owner' } } }
        @{ Response = [pscustomobject]@{ permission = 'write'; user = [pscustomobject]@{ login = 'someone-else' } } }
        @{ Response = [pscustomobject]@{ permission = 'write' } }
    ) {
        param($Response)
        $script:eligibilityResponse = $Response
        { Get-AvmPrReviewerRoutingEligibility -Repository $script:eligibilityRepository -Handle owner -Type user } |
            Should -Throw '*invalid reviewer permissions*'
    }

    It 'rejects substituted and ambiguous team permission responses' -TestCases @(
        @{ Repository = 'Azure/other'; Push = $true }
        @{ Repository = 'Azure/terraform-azure-avm-res-storage-storageaccount'; Push = 'true' }
        @{ Repository = 'Azure/terraform-azure-avm-res-storage-storageaccount'; Push = $null }
    ) {
        param($Repository, $Push)
        $script:eligibilityResponse = [pscustomobject]@{
            full_name = $Repository
            permissions = [pscustomobject]@{ push = $Push }
        }
        { Get-AvmPrReviewerRoutingEligibility -Repository $script:eligibilityRepository -Handle $script:ownersGroup -Type team } |
            Should -Throw '*invalid reviewer permissions*'
    }
}

Describe 'Reviewer eligibility fallback decisions' {
    BeforeEach {
        $script:eligibilityPr = New-EligibilityPullRequest
        $script:eligibilityIndex = @{ '.' = @{ owners = @((New-EligibilityOwner -Handle 'ineligible-owner')) } }
        Mock Get-AvmPrReviewerRoutingEligibility {
            param($Handle)
            @{ Eligible = $Handle -ine 'ineligible-owner'; Reason = 'the owner does not have repository write access' }
        }
        Mock Get-AvmPrReviewerRoutingChangedFiles { @('main.tf') }
        Mock Assert-AvmPrReviewerRoutingApplied { }
        Mock Invoke-RepositoryGitHub { $null }
    }

    It 'replaces ineligible owners with the owners group without orphaning owned modules: <Ecosystem>' -TestCases @(
        @{ Ecosystem = 'terraform'; Path = 'main.tf'; ModulePath = '.'; Repository = 'Azure/terraform-azure-avm-res-storage-storageaccount' }
        @{ Ecosystem = 'bicep'; Path = 'avm/res/storage/storage-account/main.bicep'; ModulePath = 'avm/res/storage/storage-account'; Repository = 'Azure/bicep-registry-modules' }
    ) {
        param($Ecosystem, $Path, $ModulePath, $Repository)
        $index = @{ $ModulePath = @{ owners = @((New-EligibilityOwner -Handle 'ineligible-owner')) } }
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository $Repository `
            -CatalogIndex $index -ChangedFilePaths @($Path) -Ecosystem $Ecosystem 3>$null
        $routing.NewReviewers | Should -Be @($script:ownersGroup)
        $routing.ReviewerModules[$script:ownersGroup] | Should -Be @($ModulePath)
        $routing.ReviewerTypes[$script:ownersGroup] | Should -Be 'team'
        $routing.NewLabels | Should -Be @('Needs: Module Owner :mega:')
        $routing.OrphanedModules | Should -HaveCount 0
        $routing.Warnings | Should -HaveCount 1
        $routing.SkippedReviewers[0].Reason | Should -Match 'ineligible'
    }

    It 'keeps eligible co-owners while replacing only the ineligible owner' {
        $script:eligibilityIndex['.'].owners += New-EligibilityOwner -Handle eligible-owner
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository $script:eligibilityRepository `
            -CatalogIndex $script:eligibilityIndex -ChangedFilePaths @('main.tf') -Ecosystem terraform 3>$null
        $routing.NewReviewers | Should -Be @($script:ownersGroup, 'eligible-owner')
        $routing.ReviewerModules['eligible-owner'] | Should -Be @('.')
        $routing.NewReviewers | Should -Not -Contain 'ineligible-owner'
    }

    It 'uses the same fallback for an ineligible declared team owner' {
        $script:eligibilityIndex['.'].owners = @((New-EligibilityOwner -Handle 'Azure/missing-team' -Type team))
        Mock Get-AvmPrReviewerRoutingEligibility {
            param($Handle)
            @{ Eligible = $Handle -ine 'Azure/missing-team'; Reason = 'the team has no repository write access' }
        }
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository $script:eligibilityRepository `
            -CatalogIndex $script:eligibilityIndex -ChangedFilePaths @('main.tf') -Ecosystem terraform 3>$null
        $routing.NewReviewers | Should -Be @($script:ownersGroup)
        $routing.Warnings[0] | Should -Match ([regex]::Escape('Owner [Azure/missing-team] is ineligible'))
    }

    It 'uses the group for a sole-owner author but does not call that owner ineligible' {
        $script:eligibilityPr.author.login = 'ineligible-owner'
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository $script:eligibilityRepository `
            -CatalogIndex $script:eligibilityIndex -ChangedFilePaths @('main.tf') -Ecosystem terraform
        $routing.NewReviewers | Should -Be @($script:ownersGroup)
        $routing.AuthorOwnedModules | Should -Be @('.')
        $routing.Warnings | Should -HaveCount 0
        $routing.OrphanedModules | Should -HaveCount 0
        Should -Invoke Get-AvmPrReviewerRoutingEligibility -Exactly 0 -ParameterFilter { $Handle -eq 'ineligible-owner' }
    }

    It 'does not add the group when a sole-owner author has an eligible co-owner' {
        $script:eligibilityPr.author.login = 'ineligible-owner'
        $script:eligibilityIndex['.'].owners += New-EligibilityOwner -Handle eligible-owner
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository $script:eligibilityRepository `
            -CatalogIndex $script:eligibilityIndex -ChangedFilePaths @('main.tf') -Ecosystem terraform
        $routing.NewReviewers | Should -Be @('eligible-owner')
        $routing.AuthorOwnedModules | Should -HaveCount 0
    }

    It 'falls back when an author''s only co-owner is ineligible' {
        $script:eligibilityPr.author.login = 'eligible-owner'
        $script:eligibilityIndex['.'].owners += New-EligibilityOwner -Handle eligible-owner
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository $script:eligibilityRepository `
            -CatalogIndex $script:eligibilityIndex -ChangedFilePaths @('main.tf') -Ecosystem terraform 3>$null
        $routing.NewReviewers | Should -Be @($script:ownersGroup)
        $routing.Warnings | Should -HaveCount 1
        $routing.AuthorOwnedModules | Should -HaveCount 0
    }

    It 'does not re-request a co-owner who completed a review or route them to the group' {
        $script:eligibilityPr.author.login = 'ineligible-owner'
        $script:eligibilityIndex['.'].owners += New-EligibilityOwner -Handle eligible-owner
        $script:eligibilityPr.reviews = @([pscustomobject]@{ state = 'APPROVED'; author = [pscustomobject]@{ login = 'eligible-owner' } })
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository $script:eligibilityRepository `
            -CatalogIndex $script:eligibilityIndex -ChangedFilePaths @('main.tf') -Ecosystem terraform
        $routing.NewReviewers | Should -HaveCount 0
        Should -Invoke Get-AvmPrReviewerRoutingEligibility -Exactly 0
    }

    It 'does not treat an unfinished review as a completed review' {
        $script:eligibilityIndex['.'].owners = @((New-EligibilityOwner -Handle eligible-owner))
        $script:eligibilityPr.reviews = @([pscustomobject]@{ state = 'PENDING'; author = [pscustomobject]@{ login = 'eligible-owner' } })
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository $script:eligibilityRepository `
            -CatalogIndex $script:eligibilityIndex -ChangedFilePaths @('main.tf') -Ecosystem terraform
        $routing.NewReviewers | Should -Be @('eligible-owner')
    }

    It 'checks pending owners too when their repository access has become ineligible' {
        $script:eligibilityPr.reviewRequests = @([pscustomobject]@{ login = 'ineligible-owner' })
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository $script:eligibilityRepository `
            -CatalogIndex $script:eligibilityIndex -ChangedFilePaths @('main.tf') -Ecosystem terraform 3>$null
        $routing.NewReviewers | Should -Be @($script:ownersGroup)
        $routing.Warnings | Should -HaveCount 1
    }

    It 'does not request an already-pending fallback group again, but still warns about the owner' {
        $script:eligibilityPr.reviewRequests = @([pscustomobject]@{ slug = 'azure-verified-modules-module-owners' })
        $script:eligibilityPr.labels = @([pscustomobject]@{ name = 'Needs: Module Owner :mega:' })
        $outcome = Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:eligibilityPr `
            -Repository $script:eligibilityRepository -CatalogIndex $script:eligibilityIndex -Ecosystem terraform 3>$null 6>$null
        $outcome.Status | Should -Be 'AlreadyRouted'
        $outcome.Warnings | Should -HaveCount 1
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
        Should -Invoke Assert-AvmPrReviewerRoutingApplied -Exactly 0
    }

    It 'deduplicates the group across changed modules and preserves the per-module reasons' {
        $script:eligibilityPr.author.login = 'author-owner'
        $index = @{
            'avm/res/network/virtual-network' = @{ owners = @((New-EligibilityOwner -Handle author-owner)) }
            'avm/res/storage/storage-account' = @{ owners = @((New-EligibilityOwner -Handle ineligible-owner)) }
            'avm/res/key-vault/vault' = @{ owners = @((New-EligibilityOwner -Handle eligible-owner)) }
        }
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $index -ChangedFilePaths @(
                'avm/res/network/virtual-network/main.bicep'
                'avm/res/storage/storage-account/main.bicep'
                'avm/res/key-vault/vault/main.bicep'
            ) 3>$null
        $routing.NewReviewers | Should -Be @($script:ownersGroup, 'eligible-owner')
        $routing.ReviewerModules[$script:ownersGroup] | Should -Be @('avm/res/network/virtual-network', 'avm/res/storage/storage-account')
        $routing.ReviewerModules['eligible-owner'] | Should -Be @('avm/res/key-vault/vault')
        $routing.AuthorOwnedModules | Should -Be @('avm/res/network/virtual-network')
    }

    It 'deduplicates a shared owner case-insensitively without losing their module mapping' {
        $index = @{
            'avm/res/network/virtual-network' = @{ owners = @((New-EligibilityOwner -Handle 'Ineligible-Owner')) }
            'avm/res/storage/storage-account' = @{ owners = @((New-EligibilityOwner -Handle 'ineligible-owner')) }
        }
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $index -ChangedFilePaths @(
                'avm/res/network/virtual-network/main.bicep'
                'avm/res/storage/storage-account/main.bicep'
            ) 3>$null
        $routing.NewReviewers | Should -Be @($script:ownersGroup)
        $routing.ReviewerModules[$script:ownersGroup] | Should -Be @('avm/res/network/virtual-network', 'avm/res/storage/storage-account')
        $routing.Warnings | Should -HaveCount 1
        Should -Invoke Get-AvmPrReviewerRoutingEligibility -Exactly 1 -ParameterFilter { $Handle -ieq 'ineligible-owner' }
    }

    It 'does not turn failed permission reads into guesses or fallback requests' {
        Mock Get-AvmPrReviewerRoutingEligibility { throw [System.InvalidOperationException]::new('permission read forbidden') }
        { Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository $script:eligibilityRepository `
            -CatalogIndex $script:eligibilityIndex -ChangedFilePaths @('main.tf') -Ecosystem terraform } | Should -Throw '*permission read forbidden*'
        Should -Invoke Get-AvmPrReviewerRoutingEligibility -Exactly 0 -ParameterFilter { $Type -eq 'team' }
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'fails explicitly when the fallback group is itself ineligible and still emits the owner warning' {
        Mock Get-AvmPrReviewerRoutingEligibility { @{ Eligible = $false; Reason = 'no repository write access' } }
        $output = & {
            try {
                Resolve-AvmPrReviewerRouting -PullRequest $script:eligibilityPr -Repository $script:eligibilityRepository `
                    -CatalogIndex $script:eligibilityIndex -ChangedFilePaths @('main.tf') -Ecosystem terraform 3>&1
            }
            catch {
                "THREW: $($_.Exception.Message)"
            }
        }
        $output -join "`n" | Should -Match 'Owner \[ineligible-owner\] is ineligible'
        $output -join "`n" | Should -Match 'THREW: Fallback owners group.*cannot review'
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'keeps WhatIf write-free while showing the fallback plan and warnings' {
        $outcome = Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:eligibilityPr `
            -Repository $script:eligibilityRepository -CatalogIndex $script:eligibilityIndex -Ecosystem terraform -WhatIf 3>$null 6>$null
        $outcome.Status | Should -Be 'WouldUpdate'
        $outcome.NewReviewers | Should -Be @($script:ownersGroup)
        $outcome.Warnings | Should -HaveCount 1
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
        Should -Invoke Assert-AvmPrReviewerRoutingApplied -Exactly 0
    }
}

Describe 'Reviewer eligibility workflow warnings' {
    BeforeEach {
        $script:previousEligibilityActions = $env:GITHUB_ACTIONS
        $script:previousEligibilitySummary = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'summary.md'
    }

    AfterEach {
        [System.Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $(if ($null -eq $script:previousEligibilityActions) { [NullString]::Value } else { $script:previousEligibilityActions }), 'Process')
        [System.Environment]::SetEnvironmentVariable('GITHUB_STEP_SUMMARY', $(if ($null -eq $script:previousEligibilitySummary) { [NullString]::Value } else { $script:previousEligibilitySummary }), 'Process')
    }

    It 'writes both a warning record and a correctly escaped native workflow annotation' {
        $env:GITHUB_ACTIONS = 'true'
        $output = @(Write-AvmPrReviewerRoutingWarning -Message "owner%value`n::error::not a command`r" 3>&1 6>&1)
        @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) | Should -HaveCount 1
        $annotations = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $annotations | Should -HaveCount 1
        $annotations[0].MessageData | Should -Be '::warning title=Module reviewer routing::owner%25value%0A::error::not a command%0D'
    }

    It 'uses the warning stream without workflow commands outside Actions' {
        $env:GITHUB_ACTIONS = ''
        $output = @(Write-AvmPrReviewerRoutingWarning -Message 'ineligible owner' 3>&1 6>&1)
        @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) | Should -HaveCount 1
        @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) | Should -HaveCount 0
    }

    It 'keeps owner warnings in a successful or already-routed request summary' {
        $warning = 'Owner [owner] is ineligible; using the owners group.'
        $outcome = [ordered]@{
            Url = "https://github.com/$script:eligibilityRepository/pull/1"
            Number = 1
            Status = 'AlreadyRouted'
            NewReviewers = @()
            NewLabels = @()
            ReviewerModules = @{}
            Warnings = @($warning)
        }
        Write-AvmPrReviewerRoutingSummary -Repository $script:eligibilityRepository -Outcomes @($outcome) -Failures @() 6>$null
        $summary = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
        $summary | Should -Match '0 failed\. 1 warning\(s\)\.'
        $summary | Should -Match ([regex]::Escape($warning))
        $summary | Should -Match '(?m)^Warnings:'
        $summary | Should -Not -Match '(?m)^Failures:'
    }
}

Describe 'Assert-AvmPrReviewerRoutingApplied' {
    BeforeEach {
        $script:verificationBefore = New-EligibilityPullRequest
        $script:verificationAfter = New-EligibilityPullRequest
        $script:verificationAfter.labels = @([pscustomobject]@{ name = 'Needs: Module Owner :mega:' })
        $script:verificationAfter.reviewRequests = @([pscustomobject]@{ login = 'owner' })
        $script:verificationRouting = @{
            NewReviewers = @('owner')
            NewLabels = @('Needs: Module Owner :mega:')
            ReviewerTypes = @{ owner = 'user' }
        }
        Mock Get-AvmPrReviewerRoutingCandidates { @($script:verificationAfter) }
    }

    It 'accepts a user request that is actually present and labels that were persisted' {
        Assert-AvmPrReviewerRoutingApplied -PullRequest $script:verificationBefore `
            -Repository $script:eligibilityRepository -Routing $script:verificationRouting
        Should -Invoke Get-AvmPrReviewerRoutingCandidates -Exactly 1 -ParameterFilter { $PullRequestUrl -eq $script:verificationBefore.url }
    }

    It 'accepts the owners group only when its team request appears' {
        $script:verificationAfter.reviewRequests = @([pscustomobject]@{ slug = 'azure-verified-modules-module-owners' })
        $script:verificationRouting.NewReviewers = @($script:ownersGroup)
        $script:verificationRouting.ReviewerTypes = @{ $script:ownersGroup = 'team' }
        Assert-AvmPrReviewerRoutingApplied -PullRequest $script:verificationBefore `
            -Repository $script:eligibilityRepository -Routing $script:verificationRouting
    }

    It 'accepts a review submitted during the write/readback interval: <ReviewState>' -TestCases @(
        @{ ReviewState = 'APPROVED' }
        @{ ReviewState = 'COMMENTED' }
        @{ ReviewState = 'CHANGES_REQUESTED' }
    ) {
        param($ReviewState)
        $script:verificationAfter.reviewRequests = @()
        $script:verificationAfter.reviews = @([pscustomobject]@{ state = $ReviewState; author = [pscustomobject]@{ login = 'owner' } })
        Assert-AvmPrReviewerRoutingApplied -PullRequest $script:verificationBefore `
            -Repository $script:eligibilityRepository -Routing $script:verificationRouting
    }

    It 'fails if the CLI succeeded without creating the user request or a completed review' {
        $script:verificationAfter.reviewRequests = @()
        $script:verificationAfter.reviews = @([pscustomobject]@{ state = 'PENDING'; author = [pscustomobject]@{ login = 'owner' } })
        { Assert-AvmPrReviewerRoutingApplied -PullRequest $script:verificationBefore `
            -Repository $script:eligibilityRepository -Routing $script:verificationRouting } | Should -Throw '*Missing reviewers:*owner*'
    }

    It 'fails if the fallback team request was silently ignored' {
        $script:verificationAfter.reviewRequests = @()
        $script:verificationRouting.NewReviewers = @($script:ownersGroup)
        $script:verificationRouting.ReviewerTypes = @{ $script:ownersGroup = 'team' }
        { Assert-AvmPrReviewerRoutingApplied -PullRequest $script:verificationBefore `
            -Repository $script:eligibilityRepository -Routing $script:verificationRouting } | Should -Throw '*Missing reviewers*module-owners*'
    }

    It 'fails if a label edit did not persist' {
        $script:verificationAfter.labels = @()
        { Assert-AvmPrReviewerRoutingApplied -PullRequest $script:verificationBefore `
            -Repository $script:eligibilityRepository -Routing $script:verificationRouting } | Should -Throw '*Missing labels*Needs: Module Owner*'
    }

    It 'propagates a failed verification read instead of claiming the write succeeded' {
        Mock Get-AvmPrReviewerRoutingCandidates { throw [System.InvalidOperationException]::new('verification read failed') }
        { Assert-AvmPrReviewerRoutingApplied -PullRequest $script:verificationBefore `
            -Repository $script:eligibilityRepository -Routing $script:verificationRouting } | Should -Throw '*verification read failed*'
    }
}

Describe 'Reviewer eligibility routing API round trip' {
    BeforeEach {
        $script:roundTripPr = New-EligibilityPullRequest
        $script:roundTripIndex = @{ '.' = @{ owners = @((New-EligibilityOwner -Handle owner)) } }
        $script:roundTripDropReviewer = $false
        $script:roundTripRequests = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RepositoryGitHub {
            param($Arguments)
            $script:roundTripRequests.Add([string[]]$Arguments)
            if ($Arguments[0] -eq 'api') {
                $endpoint = $Arguments[-1]
                if ($Arguments -match '/files\?') {
                    return @([pscustomobject]@{ filename = 'main.tf' })
                }
                if ($endpoint -like '*/collaborators/owner/permission') {
                    return [pscustomobject]@{ permission = 'read'; user = [pscustomobject]@{ login = 'owner' } }
                }
                if ($endpoint -like 'orgs/Azure/teams/*/repos/*') {
                    return [pscustomobject]@{ full_name = $script:eligibilityRepository; permissions = [pscustomobject]@{ push = $true } }
                }
                throw [System.InvalidOperationException]::new("Unexpected fixture API call: $endpoint")
            }
            if ($Arguments[1] -eq 'edit') {
                if (-not $script:roundTripDropReviewer) {
                    $script:roundTripPr.reviewRequests = @([pscustomobject]@{ slug = 'azure-verified-modules-module-owners' })
                }
                $script:roundTripPr.labels = @([pscustomobject]@{ name = 'Needs: Module Owner :mega:' })
                return $script:roundTripPr.url
            }
            if ($Arguments[1] -eq 'view') {
                return $script:roundTripPr.PSObject.Copy()
            }
            throw [System.InvalidOperationException]::new("Unexpected fixture command: $Arguments")
        }
    }

    It 'checks the owner, requests the group, reads it back, and becomes idempotent' {
        $before = $script:roundTripPr.PSObject.Copy()
        $cache = @{}
        $first = Set-AvmPrReviewerRoutingForPullRequest -PullRequest $before -Repository $script:eligibilityRepository `
            -CatalogIndex $script:roundTripIndex -Ecosystem terraform -EligibilityCache $cache 3>$null 6>$null
        $first.Status | Should -Be 'Updated'
        $first.NewReviewers | Should -Be @($script:ownersGroup)
        $first.Warnings | Should -HaveCount 1
        $second = Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:roundTripPr.PSObject.Copy() `
            -Repository $script:eligibilityRepository -CatalogIndex $script:roundTripIndex -Ecosystem terraform -EligibilityCache $cache 3>$null 6>$null
        $second.Status | Should -Be 'AlreadyRouted'
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter { $Arguments -contains 'edit' -and $Arguments -contains $script:ownersGroup }
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter { $Arguments -contains 'view' }
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter { $Arguments[-1] -like '*/collaborators/owner/permission' }
        @($script:roundTripRequests | Where-Object { $_ -contains 'PUT' -or $_ -contains 'DELETE' }) | Should -HaveCount 0
    }

    It 'does not report Updated when the successful edit silently drops the fallback reviewer' {
        $script:roundTripDropReviewer = $true
        { Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:roundTripPr.PSObject.Copy() `
            -Repository $script:eligibilityRepository -CatalogIndex $script:roundTripIndex -Ecosystem terraform 3>$null 6>$null } |
            Should -Throw '*GitHub did not apply routing*'
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter { $Arguments -contains 'edit' }
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter { $Arguments -contains 'view' }
    }
}
