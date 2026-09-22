BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $sharedLib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    $lib = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'lib'
    . (Join-Path $sharedLib 'RetryHelpers.ps1')
    . (Join-Path $sharedLib 'RepoTree.ps1')
    . (Join-Path $lib 'RepositoryFileAccess.ps1')
    . (Join-Path $lib 'ModuleOwners.ps1')
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

    It 'is triggered only by workflow_dispatch while live validation is pending' {
        $triggerNames = @([System.Text.RegularExpressions.Regex]::Matches(
                $script:triggerBlock, '(?m)^  ([A-Za-z_]+):') |
            ForEach-Object { $_.Groups[1].Value })
        $triggerNames.Count | Should -Be 1
        $triggerNames[0] | Should -Be 'workflow_dispatch'
        $script:triggerBlock | Should -Match '(?m)^\s{2}workflow_dispatch:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}schedule:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}issues:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request_target:'
    }

    It 'preserves the disabled schedules without schedule-dependent expressions' {
        $script:workflowText | Should -Match "'9,24,39,54 \* \* \* \*'"
        $script:workflowText | Should -Match "'17 3 \* \* \*'"
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
}
