BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $sharedLib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    $lib = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'lib'
    . (Join-Path $sharedLib 'RetryHelpers.ps1')
    . (Join-Path $sharedLib 'RepoTree.ps1')
    . (Join-Path $lib 'RepositoryFileAccess.ps1')
    . (Join-Path $lib 'ModuleOwners.ps1')
    . (Join-Path $lib 'RunSummary.ps1')
    . (Join-Path $lib 'IssueOwnerRouting.ps1')
}

Describe 'Get-AvmIssueOwnerRoutingModuleReference' {
    It 'extracts the module path and type from the issue template dropdown line' {
        $body = "### Module`n`navm/res/storage/storage-account`n`n### Description"
        $result = Get-AvmIssueOwnerRoutingModuleReference -Body $body
        $result.ModuleName | Should -Be 'avm/res/storage/storage-account'
        $result.ModuleType | Should -Be 'res'
    }

    It 'returns $null when the body has no module reference' {
        Get-AvmIssueOwnerRoutingModuleReference -Body "### Description`n`nSomething went wrong." | Should -BeNullOrEmpty
    }

    It 'returns $null for an empty body' {
        Get-AvmIssueOwnerRoutingModuleReference -Body '' | Should -BeNullOrEmpty
    }
}

Describe 'Get-AvmIssueOwnerRoutingCandidates' {
    BeforeEach {
        Mock Invoke-RepositoryGitHub {
            @(
                [pscustomobject]@{ number = 1; title = '[AVM Module Issue]: storage account bug'; updatedAt = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o') },
                [pscustomobject]@{ number = 2; title = '[AVM CI Environment Issue]: pipeline flaky'; updatedAt = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o') },
                [pscustomobject]@{ number = 3; title = '[AVM Module Issue]: stale'; updatedAt = (Get-Date).ToUniversalTime().AddDays(-2).ToString('o') }
            )
        }
    }

    It 'only returns module issues' {
        $result = @(Get-AvmIssueOwnerRoutingCandidates -Repository 'Azure/bicep-registry-modules' -UpdatedWithinMinutes 0)
        $result.Count | Should -Be 2
        $result.number | Should -Contain 1
        $result.number | Should -Contain 3
    }

    It 'filters by the lookback window' {
        $result = @(Get-AvmIssueOwnerRoutingCandidates -Repository 'Azure/bicep-registry-modules' -UpdatedWithinMinutes 60)
        $result.Count | Should -Be 1
        $result[0].number | Should -Be 1
    }
}

Describe 'Resolve-AvmIssueOwnerRouting' {
    BeforeEach {
        $script:catalogIndex = @{
            'avm/res/storage/storage-account' = @{
                owners = @(@{ handle = 'storage-owner'; type = 'user'; displayName = $null })
            }
        }
        $script:issue = [pscustomobject]@{
            number    = 42
            title     = '[AVM Module Issue]: cannot deploy'
            body      = "### Module`n`navm/res/storage/storage-account`n`n### Description`nDetails."
            url       = 'https://github.com/Azure/bicep-registry-modules/issues/42'
            createdAt = (Get-Date).ToUniversalTime().ToString('o')
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            author    = [pscustomobject]@{ login = 'contributor' }
            assignees = @()
            labels    = @()
            comments  = @()
        }
        Mock Test-AvmBicepModuleExists { $true }
    }

    It 'skips issues that are not module issues' {
        $script:issue.title = '[AVM CI Environment Issue]: pipeline flaky'
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents @()
        $routing.Skip | Should -BeTrue
    }

    It 'skips a module issue with no recognizable module reference' {
        $script:issue.body = 'no module line here'
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents @()
        $routing.Skip | Should -BeTrue
    }

    It 'assigns the module owner and adds the class label' {
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents @()
        $routing.AssigneesToAdd | Should -Contain 'storage-owner'
        $routing.NewLabels | Should -Contain 'Class: Resource Module :package:'
        $routing.NewComment | Should -Match 'storage-owner'
        $routing.IsOrphaned | Should -BeFalse
    }

    It 'flags an orphaned module and mentions the tooling-contributors team instead of assigning' {
        $script:catalogIndex['avm/res/storage/storage-account'].owners = @()
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents @()
        $routing.IsOrphaned | Should -BeTrue
        $routing.AssigneesToAdd | Should -BeNullOrEmpty
        $routing.NewComment | Should -Match 'azure-verified-modules-tooling-contributors'
    }

    It 'replies that the module does not exist yet when it is unknown to both the catalog and metadata.json' {
        Mock Test-AvmBicepModuleExists { $false }
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents @()
        $routing.ModuleExists | Should -BeFalse
        $routing.NewComment | Should -Match 'does not exist yet'
        $routing.NewLabels | Should -BeNullOrEmpty
    }

    It 'does not re-request an owner already assigned' {
        $script:issue.assignees = @([pscustomobject]@{ login = 'storage-owner' })
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents @()
        $routing.AssigneesToAdd | Should -BeNullOrEmpty
    }

    It 'does not re-assign an owner who was manually unassigned' {
        $timeline = @([pscustomobject]@{ event = 'unassigned'; assignee = [pscustomobject]@{ login = 'storage-owner' } })
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents $timeline
        $routing.AssigneesToAdd | Should -BeNullOrEmpty
    }

    It 'removes a bot-assigned excess assignee who is not a module owner' {
        $script:issue.assignees = @([pscustomobject]@{ login = 'someone-else' })
        $timeline = @([pscustomobject]@{ event = 'assigned'; actor = [pscustomobject]@{ login = 'azure-verified-modules[bot]' }; assignee = [pscustomobject]@{ login = 'someone-else' } })
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents $timeline
        $routing.AssigneesToRemove | Should -Contain 'someone-else'
    }

    It 'keeps a manually assigned excess assignee' {
        $script:issue.assignees = @([pscustomobject]@{ login = 'someone-else' })
        $timeline = @([pscustomobject]@{ event = 'assigned'; actor = [pscustomobject]@{ login = 'a-human' }; assignee = [pscustomobject]@{ login = 'someone-else' } })
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents $timeline
        $routing.AssigneesToRemove | Should -BeNullOrEmpty
    }

    It 'does not repeat an initial comment that was already posted, once the issue is more than 7 days old' {
        $script:issue.createdAt = (Get-Date).ToUniversalTime().AddDays(-30).ToString('o')
        $mentions = '@storage-owner'
        $existingComment = "**@contributor, thanks for submitting this issue for the ``avm/res/storage/storage-account`` module!**`n`n> [!IMPORTANT]`n> The module owners $mentions will review it soon!"
        $script:issue.comments = @([pscustomobject]@{ body = $existingComment })
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents @()
        $routing.NewComment | Should -BeNullOrEmpty
    }

    It 'still comments on an old orphaned issue' {
        $script:issue.createdAt = (Get-Date).ToUniversalTime().AddDays(-30).ToString('o')
        $script:catalogIndex['avm/res/storage/storage-account'].owners = @()
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents @()
        $routing.NewComment | Should -Not -BeNullOrEmpty
    }

    It 'reports every owner and the owners it will not reassign after a manual unassignment' {
        $script:catalogIndex['avm/res/storage/storage-account'].owners = @(
            @{ handle = 'storage-owner'; type = 'user'; displayName = $null },
            @{ handle = 'second-owner'; type = 'user'; displayName = $null }
        )
        $timeline = @([pscustomobject]@{ event = 'unassigned'; assignee = [pscustomobject]@{ login = 'second-owner' } })
        $routing = Resolve-AvmIssueOwnerRouting -Issue $script:issue -Repository 'Azure/bicep-registry-modules' `
            -CatalogIndex $script:catalogIndex -DefaultRef 'main' -TimelineEvents $timeline
        $routing.Owners | Should -Be @('storage-owner', 'second-owner')
        $routing.AssigneesToAdd | Should -Be @('storage-owner')
        $routing.ManuallyUnassignedOwners | Should -Be @('second-owner')
    }
}

Describe 'Set-AvmIssueOwnerRoutingForIssue' {
    BeforeEach {
        $script:issue = [pscustomobject]@{
            number    = 42
            title     = '[AVM Module Issue]: cannot deploy'
            body      = "### Module`n`navm/res/storage/storage-account`n`n### Description`nDetails."
            url       = 'https://github.com/Azure/bicep-registry-modules/issues/42'
            createdAt = (Get-Date).ToUniversalTime().ToString('o')
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            author    = [pscustomobject]@{ login = 'contributor' }
            assignees = @()
            labels    = @()
            comments  = @()
        }
        $script:catalogIndex = @{
            'avm/res/storage/storage-account' = @{
                owners = @(@{ handle = 'storage-owner'; type = 'user'; displayName = $null })
            }
        }
        Mock Get-AvmIssueOwnerRoutingTimeline { @() }
        Mock Invoke-RepositoryGitHub { }
    }

    It 'applies the computed labels, comment, and assignment' {
        Set-AvmIssueOwnerRoutingForIssue -Issue $script:issue -Repository 'Azure/bicep-registry-modules' -CatalogIndex $script:catalogIndex -DefaultRef 'main'
        Should -Invoke Invoke-RepositoryGitHub -Times 3
    }

    It 'is a no-op once the issue is already routed' {
        $script:issue.labels = @([pscustomobject]@{ name = 'Class: Resource Module :package:' })
        $script:issue.assignees = @([pscustomobject]@{ login = 'storage-owner' })
        $mentions = '@storage-owner'
        $script:issue.comments = @([pscustomobject]@{ body = "**@contributor, thanks for submitting this issue for the ``avm/res/storage/storage-account`` module!**`n`n> [!IMPORTANT]`n> The module owners $mentions will review it soon!" })
        Set-AvmIssueOwnerRoutingForIssue -Issue $script:issue -Repository 'Azure/bicep-registry-modules' -CatalogIndex $script:catalogIndex -DefaultRef 'main'
        Should -Invoke Invoke-RepositoryGitHub -Times 0
    }

    It 'logs the module owners and the changes, and returns the outcome' {
        $output = @(Set-AvmIssueOwnerRoutingForIssue -Issue $script:issue -Repository 'Azure/bicep-registry-modules' -CatalogIndex $script:catalogIndex -DefaultRef 'main' 6>&1)
        $log = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) -join "`n"
        $outcome = $output | Where-Object { $_ -is [System.Collections.Specialized.OrderedDictionary] }

        $log | Should -Match ([regex]::Escape("Issue [$($script:issue.url)] is about module [avm/res/storage/storage-account], owned by storage-owner."))
        $log | Should -Match ([regex]::Escape('Assigning: storage-owner'))
        $log | Should -Match ([regex]::Escape('Adding labels: Class: Resource Module :package:'))
        $outcome.Status | Should -Be 'Updated'
        $outcome.ModuleName | Should -Be 'avm/res/storage/storage-account'
        $outcome.AssigneesAdded | Should -Be @('storage-owner')
        $outcome.LabelsAdded | Should -Be @('Class: Resource Module :package:')
        $outcome.Commented | Should -BeTrue
    }

    It 'reports what it would change without writing under WhatIf' {
        $outcome = Set-AvmIssueOwnerRoutingForIssue -Issue $script:issue -Repository 'Azure/bicep-registry-modules' -CatalogIndex $script:catalogIndex -DefaultRef 'main' -WhatIf 6>$null
        $outcome.Status | Should -Be 'WouldUpdate'
        $outcome.AssigneesAdded | Should -Be @('storage-owner')
        Should -Invoke Invoke-RepositoryGitHub -Times 0 -Exactly
    }
}

Describe 'Invoke-AvmIssueOwnerRouting summary' {
    BeforeEach {
        $script:previousSummary = $env:GITHUB_STEP_SUMMARY
        $script:summaryPath = Join-Path $TestDrive 'summary.md'
        Remove-Item -LiteralPath $script:summaryPath -ErrorAction SilentlyContinue
        $env:GITHUB_STEP_SUMMARY = $script:summaryPath
        $script:issue = [pscustomobject]@{
            number    = 42
            title     = '[AVM Module Issue]: cannot deploy'
            body      = "### Module`n`navm/res/storage/storage-account`n`n### Description`nDetails."
            url       = 'https://github.com/Azure/bicep-registry-modules/issues/42'
            createdAt = (Get-Date).ToUniversalTime().ToString('o')
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            author    = [pscustomobject]@{ login = 'contributor' }
            assignees = @()
            labels    = @()
            comments  = @()
        }
        Mock Get-AvmIssueOwnerRoutingCandidates { @($script:issue) }
        Mock Get-AvmReviewerRoutingCatalogIndex {
            @{ 'avm/res/storage/storage-account' = @{ owners = @(@{ handle = 'storage-owner'; type = 'user'; displayName = $null }) } }
        }
        Mock Get-AvmIssueOwnerRoutingTimeline { @() }
        Mock Invoke-RepositoryGitHub { }
    }

    AfterEach {
        $env:GITHUB_STEP_SUMMARY = $script:previousSummary
    }

    It 'lists the owners assigned to each issue in the log and the job summary' {
        $log = Invoke-AvmIssueOwnerRouting -Repository 'Azure/bicep-registry-modules' 6>&1 | Out-String
        $log | Should -Match ([regex]::Escape('1 module issue(s) checked in [Azure/bicep-registry-modules]: 1 updated, 0 already routed, 0 without a module reference, 0 failed.'))
        $log | Should -Match ([regex]::Escape("$($script:issue.url) (avm/res/storage/storage-account): assigned storage-owner; added labels Class: Resource Module :package:; posted the owner notification comment"))

        $summary = Get-Content -Raw -LiteralPath $script:summaryPath
        $summary | Should -Match '(?m)^### Issue owner routing\r?$'
        $summary | Should -Match ([regex]::Escape('| [#42](https://github.com/Azure/bicep-registry-modules/issues/42) | `avm/res/storage/storage-account` | assigned `storage-owner`<br>'))
    }

    It 'describes a WhatIf run as a dry run' {
        $null = Invoke-AvmIssueOwnerRouting -Repository 'Azure/bicep-registry-modules' -WhatIf 6>&1
        $summary = Get-Content -Raw -LiteralPath $script:summaryPath
        $summary | Should -Match 'Issue owner routing \(dry run, nothing changed\)'
        $summary | Should -Match '1 would be updated'
        $summary | Should -Match ([regex]::Escape('would assign `storage-owner`'))
        Should -Invoke Invoke-RepositoryGitHub -Times 0 -Exactly
    }
}

Describe 'Invoke-AvmIssueOwnerRouting diagnostics' {
    BeforeEach {
        $script:issue1 = [pscustomobject]@{
            number    = 42
            title     = '[AVM CI Environment Issue]: not a module issue'
            body      = 'no module line here'
            url       = 'https://github.com/Azure/bicep-registry-modules/issues/42'
            createdAt = (Get-Date).ToUniversalTime().ToString('o')
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            author    = [pscustomobject]@{ login = 'contributor' }
            assignees = @()
            labels    = @()
            comments  = @()
        }
        Mock Get-AvmReviewerRoutingCatalogIndex { @{} }
        Mock Get-AvmIssueOwnerRoutingTimeline { @() }
    }

    It 'emits a per-item progress marker for every issue before it is processed' {
        Mock Get-AvmIssueOwnerRoutingCandidates { @($script:issue1) }
        $verboseOutput = Invoke-AvmIssueOwnerRouting -Repository 'Azure/bicep-registry-modules' -Verbose 4>&1 | Out-String
        $verboseOutput | Should -Match ([regex]::Escape("[1/1] Routing issue [$($script:issue1.url)]"))
    }

    It 'writes full exception detail and rethrows when pre-loop setup fails' {
        Mock Get-AvmIssueOwnerRoutingCandidates { throw [System.InvalidOperationException]::new('candidate fetch boom') }
        $hostOutput = & {
            try { Invoke-AvmIssueOwnerRouting -Repository 'Azure/bicep-registry-modules' *>&1 }
            catch { "THREW: $($_.Exception.Message)" }
        } | Out-String
        $hostOutput | Should -Match 'candidate fetch boom'
        $hostOutput | Should -Match 'InvalidOperationException'
        $hostOutput | Should -Match 'THREW: candidate fetch boom'
    }
}

Describe 'Invoke-AvmIssueOwnerRouting entry point diagnostics' {
    BeforeAll {
        $script:entryPointPath = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'Invoke-AvmIssueOwnerRouting.ps1'
        $script:entryPointText = Get-Content -Raw -Path $script:entryPointPath
    }

    It 'exists' {
        Test-Path $script:entryPointPath | Should -BeTrue
    }

    It 'wraps the sweep invocation in a try/catch that prints a FATAL banner and rethrows' {
        $script:entryPointText | Should -Match '(?ms)try\s*\{\s*Invoke-AvmIssueOwnerRouting\b.*?\}\s*catch\s*\{.*?Write-Host\s+"FATAL:.*?Write-Host\s+\$_\.ScriptStackTrace.*?throw\s*\r?\n\}'
    }
}

Describe 'Issue owner routing workflow safety' {
    BeforeAll {
        $script:workflowPath = Join-Path $root '.github' 'workflows' 'repository-management-issue-owner-routing.yml'
        $script:workflowText = Get-Content -Raw -Path $script:workflowPath
        $script:triggerBlock = [System.Text.RegularExpressions.Regex]::Match(
            $script:workflowText, '(?ms)^on:\r?\n(.*?)(?=^\S)').Groups[1].Value
        $script:runBlocks = [System.Text.RegularExpressions.Regex]::Matches(
            $script:workflowText, '(?ms)^        run:\s*\|\r?\n(?<body>.*?)(?=^      - |\z)')
    }

    It 'exists' {
        Test-Path $script:workflowPath | Should -BeTrue
    }

    It 'is triggered only by schedule and workflow_dispatch, never pull_request(_target) or issues' {
        $triggerNames = @([System.Text.RegularExpressions.Regex]::Matches(
                $script:triggerBlock, '(?m)^  ([A-Za-z_]+):') |
            ForEach-Object { $_.Groups[1].Value })
        $triggerNames.Count | Should -Be 2
        $triggerNames | Should -Contain 'workflow_dispatch'
        $triggerNames | Should -Contain 'schedule'
        $script:triggerBlock | Should -Match '(?m)^\s{2}workflow_dispatch:'
        $script:triggerBlock | Should -Match '(?m)^\s{2}schedule:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}issues:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request_target:'
    }

    It 'runs the offset crons and passes the triggering event to the run step via env, not the run body' {
        $script:workflowText | Should -Match "- cron:\s*'9,24,39,54 \* \* \* \*'"
        $script:workflowText | Should -Match "- cron:\s*'17 3 \* \* \*'"
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
        $runBody | Should -Match "'9,24,39,54 \* \* \* \*'\s*\{\s*60\s*\}"
        $runBody | Should -Match "'17 3 \* \* \*'\s*\{\s*0\s*\}"
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
