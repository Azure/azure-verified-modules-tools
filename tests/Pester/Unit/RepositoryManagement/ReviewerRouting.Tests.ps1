BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $sharedLib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    $lib = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'lib'
    . (Join-Path $sharedLib 'RetryHelpers.ps1')
    . (Join-Path $sharedLib 'RepoTree.ps1')
    . (Join-Path $lib 'RepositoryFileAccess.ps1')
    . (Join-Path $lib 'ModuleOwners.ps1')
    . (Join-Path $lib 'RunSummary.ps1')
    . (Join-Path $lib 'PrReviewerRouting.ps1')
}

Describe 'Get-AvmBicepTopLevelModulePath' {
    It 'reduces a changed file path to its top-level module folder' {
        Get-AvmBicepTopLevelModulePath -Path 'avm/res/storage/storage-account/blob-service/main.bicep' |
            Should -Be 'avm/res/storage/storage-account'
    }

    It 'returns $null for a path outside a module folder' {
        Get-AvmBicepTopLevelModulePath -Path '.github/workflows/ci.yml' | Should -BeNullOrEmpty
    }

    It 'returns $null for a bare module folder without a top-level module beneath it' {
        Get-AvmBicepTopLevelModulePath -Path 'avm/res/readme.md' | Should -BeNullOrEmpty
    }

    It 'returns $null for the non-ownable example/template scaffold' {
        Get-AvmBicepTopLevelModulePath -Path 'avm/ptn/example/module/main.bicep' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-AvmReviewerRoutingOwner (catalog owners)' {
    It 'passes through a user owner unchanged' {
        $result = @(ConvertTo-AvmReviewerRoutingOwner -Owners @(@{ handle = 'some-user'; type = 'user'; displayName = 'Some User' }))
        $result.Count | Should -Be 1
        $result[0].Handle | Should -Be 'some-user'
        $result[0].Type | Should -Be 'user'
    }

    It 'strips the leading @ from a team handle' {
        $result = @(ConvertTo-AvmReviewerRoutingOwner -Owners @(@{ handle = '@Azure/some-team'; type = 'team'; displayName = $null }))
        $result[0].Handle | Should -Be 'Azure/some-team'
        $result[0].Type | Should -Be 'team'
    }

    It 'throws on a bare string owner (pre-enrichment shape is not supported)' {
        { ConvertTo-AvmReviewerRoutingOwner -Owners @('bare-string-owner') } | Should -Throw
    }

    It 'throws on an unrecognized type' {
        { ConvertTo-AvmReviewerRoutingOwner -Owners @(@{ handle = 'x'; type = 'bot'; displayName = $null }) } | Should -Throw
    }
}

Describe 'ConvertTo-AvmReviewerRoutingMetadataOwner' {
    It 'classifies a bare username as a user' {
        $result = @(ConvertTo-AvmReviewerRoutingMetadataOwner -Owners @('some-user') -Source 'test')
        $result[0].Handle | Should -Be 'some-user'
        $result[0].Type | Should -Be 'user'
    }

    It 'classifies an @org/team-slug handle as a team and strips the @' {
        $result = @(ConvertTo-AvmReviewerRoutingMetadataOwner -Owners @('@Azure/some-team') -Source 'test')
        $result[0].Handle | Should -Be 'Azure/some-team'
        $result[0].Type | Should -Be 'team'
    }

    It 'deduplicates case-insensitively' {
        $result = @(ConvertTo-AvmReviewerRoutingMetadataOwner -Owners @('Some-User', 'some-user') -Source 'test')
        $result.Count | Should -Be 1
    }

    It 'throws on an invalid handle' {
        { ConvertTo-AvmReviewerRoutingMetadataOwner -Owners @('not a valid handle!') -Source 'test' } | Should -Throw
    }
}

Describe 'Get-AvmModuleOwners' {
    BeforeEach {
        $script:catalogIndex = @{
            'avm/res/storage/storage-account' = @{
                owners = @(@{ handle = 'catalog-owner'; type = 'user'; displayName = $null })
            }
        }
    }

    It 'resolves from the catalog index when the module is present and not force-refreshed' {
        Mock Get-AvmBicepModuleMetadataOwners { throw 'should not read metadata.json when the catalog has an entry' }
        $owners = @(Get-AvmModuleOwners -TopLevelModulePath 'avm/res/storage/storage-account' -CatalogIndex $script:catalogIndex `
            -Repository 'Azure/bicep-registry-modules' -Ref 'deadbeef')
        $owners[0].Handle | Should -Be 'catalog-owner'
    }

    It 'falls back to metadata.json when the module is absent from the catalog index' {
        Mock Get-AvmBicepModuleMetadataOwners { @(@{ Handle = 'metadata-owner'; Type = 'user' }) }
        $owners = @(Get-AvmModuleOwners -TopLevelModulePath 'avm/res/new/module' -CatalogIndex $script:catalogIndex `
            -Repository 'Azure/bicep-registry-modules' -Ref 'deadbeef')
        $owners[0].Handle | Should -Be 'metadata-owner'
        Should -Invoke Get-AvmBicepModuleMetadataOwners -Exactly 1
    }

    It 'bypasses a stale catalog entry when ForceMetadataLookup is set' {
        Mock Get-AvmBicepModuleMetadataOwners { @(@{ Handle = 'fresh-owner'; Type = 'user' }) }
        $owners = @(Get-AvmModuleOwners -TopLevelModulePath 'avm/res/storage/storage-account' -CatalogIndex $script:catalogIndex `
            -Repository 'Azure/bicep-registry-modules' -Ref 'deadbeef' -ForceMetadataLookup)
        $owners[0].Handle | Should -Be 'fresh-owner'
    }
}

Describe 'Resolve-AvmPrReviewerRouting' {
    BeforeEach {
        $script:catalogIndex = @{
            'avm/res/storage/storage-account' = @{
                owners = @(@{ handle = 'storage-owner'; type = 'user'; displayName = $null })
            }
        }
        $script:pr = [pscustomobject]@{
            author = [pscustomobject]@{ login = 'contributor' }
            number = 1
            url = 'https://github.com/Azure/bicep-registry-modules/pull/1'
            isDraft = $false
            reviewRequests = @()
            reviews = @()
            headRefOid = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
            labels = @()
        }
    }

    It 'requests the module owner and labels the pull request as needing a module owner' {
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/storage/storage-account/main.bicep')
        $routing.NewReviewers | Should -Contain 'storage-owner'
        $routing.NewLabels | Should -Contain 'Needs: Module Owner :mega:'
        $routing.NewLabels | Should -Not -Contain 'Status: Module Orphaned :yellow_circle:'
    }

    It 'falls back to the shared owners team and flags the module as orphaned' {
        Mock Get-AvmBicepModuleMetadataOwners { @() }
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/network/virtual-network/main.bicep')
        $routing.NewReviewers | Should -Contain 'Azure/azure-verified-modules-module-owners'
        $routing.NewLabels | Should -Contain 'Needs: Core Team :genie:'
        $routing.NewLabels | Should -Contain 'Status: Module Orphaned :yellow_circle:'
    }

    It 'routes to the core team when a changed file is outside any module folder' {
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/storage/storage-account/main.bicep', 'utilities/pipelines/e2e.ps1')
        $routing.NewLabels | Should -Contain 'Needs: Core Team :genie:'
    }

    It 'skips the pull request author and already-requested reviewers' {
        $script:pr.author.login = 'storage-owner'
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/storage/storage-account/main.bicep')
        $routing.NewReviewers | Should -BeNullOrEmpty
    }

    It 'is a no-op once the desired labels and reviewers are already present' {
        $script:pr.labels = @([pscustomobject]@{ name = 'Needs: Module Owner :mega:' })
        $script:pr.reviewRequests = @([pscustomobject]@{ login = 'storage-owner' })
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/storage/storage-account/main.bicep')
        $routing.NewReviewers | Should -BeNullOrEmpty
        $routing.NewLabels | Should -BeNullOrEmpty
    }

    It 'forces a metadata.json re-read when the pull request edits the module''s own metadata.json' {
        Mock Get-AvmBicepModuleMetadataOwners { @(@{ Handle = 'fresh-owner'; Type = 'user' }) }
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/storage/storage-account/metadata.json')
        $routing.NewReviewers | Should -Contain 'fresh-owner'
        Should -Invoke Get-AvmBicepModuleMetadataOwners -Exactly 1
    }

    It 'requests a team owner by Type, not by inferring from a slash in the handle' {
        # Synthetic: real catalog/metadata.json data currently has zero team owners, so this
        # path is only exercised here, not against production data.
        $script:catalogIndex['avm/res/storage/storage-account'].owners = @(@{ handle = 'Azure/storage-owners'; type = 'team'; displayName = 'Storage owners' })
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/storage/storage-account/main.bicep')
        $routing.NewReviewers | Should -Contain 'Azure/storage-owners'
    }

    It 'skips a team owner that already has a pending review request' {
        $script:catalogIndex['avm/res/storage/storage-account'].owners = @(@{ handle = 'Azure/storage-owners'; type = 'team'; displayName = 'Storage owners' })
        $script:pr.reviewRequests = @([pscustomobject]@{ slug = 'storage-owners'; name = 'Storage owners' })
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/storage/storage-account/main.bicep')
        $routing.NewReviewers | Should -BeNullOrEmpty
    }

    It 'is a no-op when the pull request author is the module''s sole declared owner' {
        # Regression: the sole owner must not be misread as "no owners" once
        # filtered out, which would incorrectly apply the orphan label.
        $script:pr.author.login = 'storage-owner'
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/storage/storage-account/main.bicep')
        $routing.NewReviewers | Should -BeNullOrEmpty
        $routing.NewLabels | Should -Not -Contain 'Status: Module Orphaned :yellow_circle:'
    }

    It 'is a no-op when every declared owner already has a pending review request' {
        $script:catalogIndex['avm/res/storage/storage-account'].owners = @(
            @{ handle = 'storage-owner'; type = 'user'; displayName = $null },
            @{ handle = 'second-owner'; type = 'user'; displayName = $null }
        )
        $script:pr.reviewRequests = @(
            [pscustomobject]@{ login = 'storage-owner' },
            [pscustomobject]@{ login = 'second-owner' }
        )
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/storage/storage-account/main.bicep')
        $routing.NewReviewers | Should -BeNullOrEmpty
        $routing.NewLabels | Should -Not -Contain 'Status: Module Orphaned :yellow_circle:'
    }

    It 'skips the non-ownable example/template scaffold entirely, without an orphan label or a metadata.json fetch' {
        Mock Get-AvmBicepModuleMetadataOwners { throw 'should never fetch metadata.json for a non-module path' }
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/ptn/example/module/main.bicep')
        $routing.NewReviewers | Should -BeNullOrEmpty
        $routing.NewLabels | Should -Contain 'Needs: Core Team :genie:'
        $routing.NewLabels | Should -Not -Contain 'Status: Module Orphaned :yellow_circle:'
        Should -Invoke Get-AvmBicepModuleMetadataOwners -Exactly 0
    }

    It 'explains the routing: each module''s owners and their source, and which modules each reviewer owns' {
        Mock Get-AvmBicepModuleMetadataOwners { @(@{ Handle = 'new-owner'; Type = 'user' }) } -ParameterFilter { $TopLevelModulePath -eq 'avm/res/new/module' }
        Mock Get-AvmBicepModuleMetadataOwners { @() } -ParameterFilter { $TopLevelModulePath -eq 'avm/res/network/virtual-network' }
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @(
                'avm/res/storage/storage-account/main.bicep',
                'avm/res/storage/storage-account/tests/e2e/defaults/main.test.bicep',
                'avm/res/new/module/main.bicep',
                'avm/res/network/virtual-network/main.bicep',
                'README.md'
            )

        @($routing.Modules | ForEach-Object { $_.ModulePath }) |
            Should -Be @('avm/res/network/virtual-network', 'avm/res/new/module', 'avm/res/storage/storage-account')
        $storage = $routing.Modules | Where-Object { $_.ModulePath -eq 'avm/res/storage/storage-account' }
        $storage.Owners | Should -Be @('storage-owner')
        $storage.Source | Should -Be 'catalog'
        ($routing.Modules | Where-Object { $_.ModulePath -eq 'avm/res/new/module' }).Source | Should -Be 'metadata.json'
        $routing.OrphanedModules | Should -Be @('avm/res/network/virtual-network')
        $routing.CoreTeamPaths | Should -Be @('README.md')
        $routing.NewReviewers | Should -Be @('Azure/azure-verified-modules-module-owners', 'new-owner', 'storage-owner')
        $routing.ReviewerModules['storage-owner'] | Should -Be @('avm/res/storage/storage-account')
        $routing.ReviewerModules['new-owner'] | Should -Be @('avm/res/new/module')
        $routing.ReviewerModules['Azure/azure-verified-modules-module-owners'] | Should -Be @('avm/res/network/virtual-network')
    }

    It 'maps an owner of several changed modules to all of them' {
        $script:catalogIndex['avm/res/network/virtual-network'] = @{
            owners = @(@{ handle = 'storage-owner'; type = 'user'; displayName = $null })
        }
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/storage/storage-account/main.bicep', 'avm/res/network/virtual-network/main.bicep')
        $routing.NewReviewers | Should -Be @('storage-owner')
        $routing.ReviewerModules['storage-owner'] | Should -Be @('avm/res/network/virtual-network', 'avm/res/storage/storage-account')
    }

    It 'reports why each owner is not requested' {
        $script:catalogIndex['avm/res/storage/storage-account'].owners = @(
            @{ handle = 'contributor'; type = 'user'; displayName = $null },
            @{ handle = 'requested-owner'; type = 'user'; displayName = $null },
            @{ handle = 'reviewing-owner'; type = 'user'; displayName = $null },
            @{ handle = 'Azure/storage-owners'; type = 'team'; displayName = 'Storage owners' }
        )
        $script:pr.reviewRequests = @(
            [pscustomobject]@{ login = 'requested-owner' },
            [pscustomobject]@{ slug = 'storage-owners'; name = 'Storage owners' }
        )
        $script:pr.reviews = @([pscustomobject]@{ author = [pscustomobject]@{ login = 'reviewing-owner' } })
        $routing = Resolve-AvmPrReviewerRouting -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -ChangedFilePaths @('avm/res/storage/storage-account/main.bicep')

        $routing.NewReviewers | Should -BeNullOrEmpty
        $reasons = @{}
        foreach ($skipped in $routing.SkippedReviewers) { $reasons[$skipped.Handle] = $skipped.Reason }
        $reasons.Count | Should -Be 4
        $reasons['contributor'] | Should -Be 'pull request author'
        $reasons['requested-owner'] | Should -Be 'review already requested'
        $reasons['reviewing-owner'] | Should -Be 'already reviewed'
        $reasons['Azure/storage-owners'] | Should -Be 'review already requested'
    }
}

Describe 'Set-AvmPrReviewerRoutingForPullRequest' {
    BeforeEach {
        $script:pr = [pscustomobject]@{
            author = [pscustomobject]@{ login = 'contributor' }
            number = 1
            url = 'https://github.com/Azure/bicep-registry-modules/pull/1'
            isDraft = $false
            reviewRequests = @()
            reviews = @()
            headRefOid = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
            labels = @()
        }
        $script:catalogIndex = @{
            'avm/res/storage/storage-account' = @{
                owners = @(@{ handle = 'storage-owner'; type = 'user'; displayName = $null })
            }
        }
        Mock Invoke-RepositoryGitHub {
            if ($Arguments[0] -eq 'api') {
                return @([pscustomobject]@{ filename = 'avm/res/storage/storage-account/main.bicep' })
            }
            return $null
        }
    }

    It 'skips draft pull requests entirely' {
        $script:pr.isDraft = $true
        Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' -CatalogIndex $script:catalogIndex
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'applies the computed labels and reviewers with gh pr edit' {
        Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' -CatalogIndex $script:catalogIndex
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter {
            $Arguments -contains 'edit' -and $Arguments -contains '--add-reviewer' -and $Arguments -contains 'storage-owner'
        }
    }

    It 'does not call gh pr edit again once the pull request is already routed' {
        $script:pr.labels = @([pscustomobject]@{ name = 'Needs: Module Owner :mega:' })
        $script:pr.reviewRequests = @([pscustomobject]@{ login = 'storage-owner' })
        Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' -CatalogIndex $script:catalogIndex
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter { $Arguments[0] -eq 'api' }
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'pr' }
    }

    It 'logs who is requested for which module and returns the outcome' {
        $output = @(Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' -CatalogIndex $script:catalogIndex 6>&1)
        $log = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) -join "`n"
        $outcome = $output | Where-Object { $_ -is [System.Collections.Specialized.OrderedDictionary] }

        $log | Should -Match ([regex]::Escape("Pull request [$($script:pr.url)] changes 1 module(s):"))
        $log | Should -Match ([regex]::Escape('avm/res/storage/storage-account: storage-owner'))
        $log | Should -Match ([regex]::Escape('storage-owner for avm/res/storage/storage-account'))
        $log | Should -Match ([regex]::Escape('Adding labels: Needs: Module Owner :mega:'))
        $outcome.Status | Should -Be 'Updated'
        $outcome.NewReviewers | Should -Be @('storage-owner')
        $outcome.NewLabels | Should -Be @('Needs: Module Owner :mega:')
        $outcome.ReviewerModules['storage-owner'] | Should -Be @('avm/res/storage/storage-account')
    }

    It 'logs the plan but does not edit the pull request under WhatIf' {
        $outcome = Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' -CatalogIndex $script:catalogIndex -WhatIf 6>$null
        $outcome.Status | Should -Be 'WouldUpdate'
        $outcome.NewReviewers | Should -Be @('storage-owner')
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'pr' }
    }

    It 'reports draft and already routed pull requests in the outcome' {
        $script:pr.isDraft = $true
        (Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' -CatalogIndex $script:catalogIndex 6>$null).Status |
            Should -Be 'Draft'

        $script:pr.isDraft = $false
        $script:pr.labels = @([pscustomobject]@{ name = 'Needs: Module Owner :mega:' })
        $script:pr.reviewRequests = @([pscustomobject]@{ login = 'storage-owner' })
        (Set-AvmPrReviewerRoutingForPullRequest -PullRequest $script:pr -Repository 'Azure/bicep-registry-modules' -CatalogIndex $script:catalogIndex 6>$null).Status |
            Should -Be 'AlreadyRouted'
    }
}

Describe 'Invoke-AvmPrReviewerRouting summary' {
    BeforeEach {
        $script:previousSummary = $env:GITHUB_STEP_SUMMARY
        $script:summaryPath = Join-Path $TestDrive 'summary.md'
        Remove-Item -LiteralPath $script:summaryPath -ErrorAction SilentlyContinue
        $env:GITHUB_STEP_SUMMARY = $script:summaryPath
        $script:pr = [pscustomobject]@{
            author = [pscustomobject]@{ login = 'contributor' }
            number = 1
            url = 'https://github.com/Azure/bicep-registry-modules/pull/1'
            isDraft = $false
            reviewRequests = @()
            reviews = @()
            headRefOid = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
            labels = @()
        }
        Mock Get-AvmPrReviewerRoutingCandidates { @($script:pr) }
        Mock Get-AvmReviewerRoutingCatalogIndex {
            @{ 'avm/res/storage/storage-account' = @{ owners = @(@{ handle = 'storage-owner'; type = 'user'; displayName = $null }) } }
        }
        Mock Invoke-RepositoryGitHub {
            if ($Arguments[0] -eq 'api') {
                return @([pscustomobject]@{ filename = 'avm/res/storage/storage-account/main.bicep' })
            }
            return $null
        }
    }

    AfterEach {
        $env:GITHUB_STEP_SUMMARY = $script:previousSummary
    }

    It 'lists who was requested for which modules in the log and the job summary' {
        $log = Invoke-AvmPrReviewerRouting -Repository 'Azure/bicep-registry-modules' 6>&1 | Out-String
        $log | Should -Match ([regex]::Escape('1 pull request(s) checked in [Azure/bicep-registry-modules]: 1 updated, 0 already routed, 0 draft(s) skipped, 0 failed.'))
        $log | Should -Match ([regex]::Escape('Reviewers requested: storage-owner for avm/res/storage/storage-account'))

        $summary = Get-Content -Raw -LiteralPath $script:summaryPath
        $summary | Should -Match '(?m)^### Pull request reviewer routing\r?$'
        $summary | Should -Match ([regex]::Escape('| [#1](https://github.com/Azure/bicep-registry-modules/pull/1) | `storage-owner` for `avm/res/storage/storage-account` | `Needs: Module Owner :mega:` |'))
    }

    It 'marks a WhatIf run as a dry run without editing the pull request' {
        $null = Invoke-AvmPrReviewerRouting -Repository 'Azure/bicep-registry-modules' -WhatIf 6>&1
        $summary = Get-Content -Raw -LiteralPath $script:summaryPath
        $summary | Should -Match 'Pull request reviewer routing \(dry run, nothing changed\)'
        $summary | Should -Match '1 would be updated'
        $summary | Should -Match '\| Pull request \| Reviewers to request \| Labels to add \|'
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'pr' }
    }

    It 'lists failed pull requests in the job summary before rethrowing' {
        Mock Invoke-RepositoryGitHub { throw [System.InvalidOperationException]::new('changed files boom') }
        { Invoke-AvmPrReviewerRouting -Repository 'Azure/bicep-registry-modules' 6>$null 3>$null } | Should -Throw '*changed files boom*'
        $summary = Get-Content -Raw -LiteralPath $script:summaryPath
        $summary | Should -Match '0 updated, 0 already routed, 0 draft\(s\) skipped, 1 failed\.'
        $summary | Should -Match ([regex]::Escape('- `[https://github.com/Azure/bicep-registry-modules/pull/1]: changed files boom`'))
    }
}

Describe 'Invoke-AvmPrReviewerRouting diagnostics' {
    BeforeEach {
        $script:pr1 = [pscustomobject]@{
            author = [pscustomobject]@{ login = 'contributor' }
            number = 1
            url = 'https://github.com/Azure/bicep-registry-modules/pull/1'
            isDraft = $true
            reviewRequests = @()
            reviews = @()
            headRefOid = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
            labels = @()
        }
        Mock Get-AvmReviewerRoutingCatalogIndex { @{} }
    }

    It 'emits a per-item progress marker for every pull request before it is processed' {
        Mock Get-AvmPrReviewerRoutingCandidates { @($script:pr1) }
        $verboseOutput = Invoke-AvmPrReviewerRouting -Repository 'Azure/bicep-registry-modules' -Verbose 4>&1 | Out-String
        $verboseOutput | Should -Match ([regex]::Escape("[1/1] Routing pull request [$($script:pr1.url)]"))
    }

    It 'writes full exception detail and rethrows when pre-loop setup fails' {
        Mock Get-AvmPrReviewerRoutingCandidates { throw [System.InvalidOperationException]::new('candidate fetch boom') }
        $hostOutput = & {
            try { Invoke-AvmPrReviewerRouting -Repository 'Azure/bicep-registry-modules' *>&1 }
            catch { "THREW: $($_.Exception.Message)" }
        } | Out-String
        $hostOutput | Should -Match 'candidate fetch boom'
        $hostOutput | Should -Match 'InvalidOperationException'
        $hostOutput | Should -Match 'THREW: candidate fetch boom'
    }
}

Describe 'Invoke-AvmPrReviewerRouting entry point diagnostics' {
    BeforeAll {
        $script:entryPointPath = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'Invoke-AvmPrReviewerRouting.ps1'
        $script:entryPointText = Get-Content -Raw -Path $script:entryPointPath
    }

    It 'exists' {
        Test-Path $script:entryPointPath | Should -BeTrue
    }

    It 'wraps the sweep invocation in a try/catch that prints a FATAL banner and rethrows' {
        $script:entryPointText | Should -Match '(?ms)try\s*\{\s*Invoke-AvmPrReviewerRouting\b.*?\}\s*catch\s*\{.*?Write-Host\s+"FATAL:.*?Write-Host\s+\$_\.ScriptStackTrace.*?throw\s*\r?\n\}'
    }
}

Describe 'Reviewer routing workflow safety' {
    BeforeAll {
        $script:workflowPath = Join-Path $root '.github' 'workflows' 'repository-management-pr-reviewer-routing.yml'
        $script:workflowText = Get-Content -Raw -Path $script:workflowPath
        # Everything from the top-level `on:` block up to the next top-level (unindented) key.
        $script:triggerBlock = [System.Text.RegularExpressions.Regex]::Match(
            $script:workflowText, '(?ms)^on:\r?\n(.*?)(?=^\S)').Groups[1].Value
        $script:runBlocks = [System.Text.RegularExpressions.Regex]::Matches(
            $script:workflowText, '(?ms)^        run:\s*\|\r?\n(?<body>.*?)(?=^      - |\z)')
    }

    It 'exists' {
        Test-Path $script:workflowPath | Should -BeTrue
    }

    It 'is triggered only by schedule and workflow_dispatch, never pull_request(_target)' {
        $triggerNames = @([System.Text.RegularExpressions.Regex]::Matches(
                $script:triggerBlock, '(?m)^  ([A-Za-z_]+):') |
            ForEach-Object { $_.Groups[1].Value })
        $triggerNames.Count | Should -Be 2
        $triggerNames | Should -Contain 'workflow_dispatch'
        $triggerNames | Should -Contain 'schedule'
        $script:triggerBlock | Should -Match '(?m)^\s{2}workflow_dispatch:'
        $script:triggerBlock | Should -Match '(?m)^\s{2}schedule:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request_target:'
    }

    It 'runs the offset crons and passes the triggering event to the run step via env, not the run body' {
        $script:workflowText | Should -Match "- cron:\s*'7,22,37,52 \* \* \* \*'"
        $script:workflowText | Should -Match "- cron:\s*'13 3 \* \* \*'"
        $script:workflowText | Should -Match '(?m)^\s{10}EVENT_NAME:\s*\$\{\{\s*github\.event_name\s*\}\}\s*$'
        $script:workflowText | Should -Match '(?m)^\s{10}EVENT_SCHEDULE:\s*\$\{\{\s*github\.event\.schedule\s*\}\}\s*$'
    }

    It 'maps dispatch inputs directly and preserves full-sweep values' {
        $script:triggerBlock | Should -Match '(?ms)^      what_if:\r?\n.*?^        default:\s*true\s*$'
        $script:workflowText | Should -Match '(?m)^\s{10}UPDATED_WITHIN_MINUTES:\s*\$\{\{\s*inputs\.updated_within_minutes\s*\}\}\s*$'
        $script:workflowText | Should -Match '(?m)^\s{10}WHAT_IF:\s*\$\{\{\s*inputs\.what_if\s*\}\}\s*$'
        $script:workflowText | Should -Match "\`$whatIf\s*=\s*\`$env:WHAT_IF\s*-eq\s*'true'"
        ([int]'') | Should -Be 0
    }

    It 'maps each scheduled cron to an explicit non-empty lookback, using the dispatch input only for workflow_dispatch' {
        # Regression: on a schedule trigger, inputs.updated_within_minutes is an empty
        # string and [int]'' casts to 0, which the candidate filter treats as "sweep
        # everything". Without an explicit per-cron mapping, every 15-minute cadence
        # run would silently become a full sweep instead of only the daily backstop.
        $workRunBlocks = @($script:runBlocks | Where-Object {
                $_.Groups['body'].Value -match '(?m)^\s*\./repository-management/.+\.ps1\b'
            })
        $workRunBlocks.Count | Should -Be 1
        $runBody = $workRunBlocks[0].Groups['body'].Value
        $runBody | Should -Match "'workflow_dispatch'\s*\{\s*\[int\]\`$env:UPDATED_WITHIN_MINUTES\s*\}"
        $runBody | Should -Match "'7,22,37,52 \* \* \* \*'\s*\{\s*60\s*\}"
        $runBody | Should -Match "'13 3 \* \* \*'\s*\{\s*0\s*\}"
        $runBody | Should -Match '(?s)default\s*\{\s*throw.*?Unexpected schedule'
        $runBody | Should -Match '(?s)default\s*\{\s*throw.*?Unexpected event'
    }

    It 'never interpolates ${{ }} expressions directly into a run: body' {
        $script:runBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $script:runBlocks) {
            $match.Groups['body'].Value | Should -Not -Match '\$\{\{'
        }
    }

    It 'imports Avm.Authoring in the work run block before invoking the repository-management script' {
        $workRunBlocks = @($script:runBlocks | Where-Object {
                $_.Groups['body'].Value -match '(?m)^\s*\./repository-management/.+\.ps1\b'
            })
        $workRunBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $workRunBlocks) {
            $runBody = $match.Groups['body'].Value
            $importIndex = $runBody.IndexOf('Import-Module Avm.Authoring -Force -ErrorAction Stop')
            $scriptIndex = [System.Text.RegularExpressions.Regex]::Match(
                $runBody, '(?m)^\s*\./repository-management/.+\.ps1\b').Index
            $importIndex | Should -BeGreaterThan -1
            $importIndex | Should -BeLessThan $scriptIndex
        }
    }

    It 'uses GH_TOKEN directly and clears native exit status after the work script' {
        $workRunBlocks = @($script:runBlocks | Where-Object {
                $_.Groups['body'].Value -match '(?m)^\s*\./repository-management/.+\.ps1\b'
            })
        $workRunBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $workRunBlocks) {
            $runBody = $match.Groups['body'].Value
            $runBody | Should -Not -Match '(?m)^\s*gh auth login\b'
            $scriptIndex = [System.Text.RegularExpressions.Regex]::Match(
                $runBody, '(?m)^\s*\./repository-management/.+\.ps1\b').Index
            $resetIndex = $runBody.LastIndexOf('$global:LASTEXITCODE = 0')
            $resetIndex | Should -BeGreaterThan $scriptIndex
            $runBody | Should -Match '(?s)\$global:LASTEXITCODE\s*=\s*0\s*\z'
        }
    }
}
