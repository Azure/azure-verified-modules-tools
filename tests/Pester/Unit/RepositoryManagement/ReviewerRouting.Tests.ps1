BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $sharedLib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    $lib = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'lib'
    . (Join-Path $sharedLib 'RetryHelpers.ps1')
    . (Join-Path $sharedLib 'RepoTree.ps1')
    . (Join-Path $lib 'RepositoryFileAccess.ps1')
    . (Join-Path $lib 'ModuleOwners.ps1')
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
}

Describe 'Reviewer routing workflow safety' {
    BeforeAll {
        $script:workflowPath = Join-Path $root '.github' 'workflows' 'repository-management-pr-reviewer-routing.yml'
        $script:workflowText = Get-Content -Raw -Path $script:workflowPath
        # Everything from the top-level `on:` block up to the next top-level (unindented) key.
        $script:triggerBlock = [System.Text.RegularExpressions.Regex]::Match(
            $script:workflowText, '(?ms)^on:\r?\n(.*?)(?=^\S)').Groups[1].Value
    }

    It 'exists' {
        Test-Path $script:workflowPath | Should -BeTrue
    }

    It 'is triggered only by workflow_dispatch while live validation is pending' {
        $triggerNames = @([System.Text.RegularExpressions.Regex]::Matches(
                $script:triggerBlock, '(?m)^  ([A-Za-z_]+):') |
            ForEach-Object { $_.Groups[1].Value })
        $triggerNames.Count | Should -Be 1
        $triggerNames[0] | Should -Be 'workflow_dispatch'
        $script:triggerBlock | Should -Match '(?m)^\s{2}workflow_dispatch:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}schedule:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request_target:'
    }

    It 'preserves the disabled schedules without schedule-dependent expressions' {
        $script:workflowText | Should -Match "'7,22,37,52 \* \* \* \*'"
        $script:workflowText | Should -Match "'13 3 \* \* \*'"
        $script:workflowText | Should -Not -Match 'github\.event\.schedule'
    }

    It 'maps dispatch inputs directly and preserves full-sweep values' {
        $script:triggerBlock | Should -Match '(?ms)^      what_if:\r?\n.*?^        default:\s*true\s*$'
        $script:workflowText | Should -Match '(?m)^\s{10}UPDATED_WITHIN_MINUTES:\s*\$\{\{\s*inputs\.updated_within_minutes\s*\}\}\s*$'
        $script:workflowText | Should -Match '(?m)^\s{10}WHAT_IF:\s*\$\{\{\s*inputs\.what_if\s*\}\}\s*$'
        $script:workflowText | Should -Match "\`$whatIf\s*=\s*\`$env:WHAT_IF\s*-eq\s*'true'"
        ([int]'') | Should -Be 0
    }

    It 'never interpolates ${{ }} expressions directly into a run: body' {
        $runBlocks = [System.Text.RegularExpressions.Regex]::Matches($script:workflowText, '(?m)^( +)run:\s*\|\r?\n((?:\1 .*\r?\n?)*)')
        $runBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $runBlocks) {
            $match.Groups[2].Value | Should -Not -Match '\$\{\{'
        }
    }
}
