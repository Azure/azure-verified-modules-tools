#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force

    function script:New-ReleaseMetadataApi {
        param(
            [string] $Author = 'alice',
            [string] $Title = 'feat: add zone support',
            [string] $Body = '- [ ] Breaking changes.',
            [string[]] $Labels = @(),
            [object[]] $Files = @(),
            [object[]] $Events = @(),
            [string[]] $Tags = @(),
            [int] $Number = 42,
            [int] $ChangedFiles = -1
        )

        $repo = 'repos/Azure/terraform-azurerm-avm-res-example'
        $count = if ($ChangedFiles -ge 0) { $ChangedFiles } else { $Files.Count }
        $responses = @{}
        $responses["$repo/pulls/$Number"] = @{
            number        = $Number
            title         = $Title
            body          = $Body
            user          = @{ login = $Author }
            labels        = @($Labels | ForEach-Object { @{ name = $_ } })
            head          = @{ sha = 'head-sha' }
            base          = @{ sha = 'base-sha' }
            changed_files = $count
        }
        $responses["$repo/issues/$Number/events?per_page=100&page=1"] = $Events
        $responses["$repo/git/matching-refs/tags/v"] = @($Tags | ForEach-Object { @{ ref = "refs/tags/$_" } })
        $responses["$repo/compare/base-sha...head-sha?per_page=1"] = @{ merge_base_commit = @{ sha = 'merge-base-sha' } }
        for ($page = 1; $page -le [math]::Max(1, [math]::Ceiling($Files.Count / 100) + 1); $page++) {
            $responses["$repo/pulls/$Number/files?per_page=100&page=$page"] = @($Files | Select-Object -Skip (($page - 1) * 100) -First 100)
        }
        return $responses
    }

    function script:New-ReleaseMetadataFile {
        param([string] $Path, [string] $Status = 'modified', [string] $PreviousPath)
        $file = @{ filename = $Path; status = $Status }
        if ($PreviousPath) {
            $file.previous_filename = $PreviousPath
        }
        return $file
    }

    function script:New-ReleaseMetadataContent {
        param([string] $Text)
        return @{ encoding = 'base64'; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) -replace '(.{60})', "`$1`n" }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmReleaseMetadataCheck' {
    BeforeEach {
        $script:eventPath = Join-Path $TestDrive 'event.json'
    }

    Context 'finding the pull request' {
        It 'reads the number from a pull_request event' {
            @{ pull_request = @{ number = 42 } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $eventPath -Encoding utf8NoBOM
            $responses = New-ReleaseMetadataApi -Labels 'minor' -Files @(New-ReleaseMetadataFile 'main.tf') -Tags 'v0.9.3', 'v0.10.0', 'v0.2.0', 'v1.0.0-beta', 'release'

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses; EventPath = $eventPath } {
                param([hashtable] $Responses, [string] $EventPath)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Test-AvmReleaseFormatEquivalence -MockWith { $true }
                Mock Write-AvmLog -MockWith { }
                $result = Invoke-AvmReleaseMetadataCheck -Repository 'Azure/terraform-azurerm-avm-res-example' -EventName 'pull_request' -EventPath $EventPath -SummaryPath '' -SkipModuleVersionCheck
                Should -Invoke Invoke-AvmGitHubApi -Exactly 0 -ParameterFilter { $Endpoint -like '*/events*' -or $Endpoint -like '*/compare/*' -or $Endpoint -like '*/contents/*' }
                Should -Invoke Test-AvmReleaseFormatEquivalence -Exactly 0
                $result
            }

            $probe.Status | Should -Be 'pass'
            $probe.Kind | Should -Be 'Human'
            $probe.VersionLabel | Should -Be 'minor'
            $probe.Repository | Should -Be 'Azure/terraform-azurerm-avm-res-example'
            $probe.PullRequest | Should -Be 42
            $probe.EventName | Should -Be 'pull_request'
        }

        It 'checks the pull request named by a merge_group head ref' {
            @{ merge_group = @{ head_ref = "refs/heads/gh-readonly-queue/main/pr-7-$('a' * 40)"; head_sha = 'b' * 40 } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $eventPath -Encoding utf8NoBOM
            $responses = New-ReleaseMetadataApi -Number 7 -Labels 'patch', 'minor' -Files @(New-ReleaseMetadataFile 'main.tf')

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses; EventPath = $eventPath } {
                param([hashtable] $Responses, [string] $EventPath)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Write-AvmLog -MockWith { }
                Invoke-AvmReleaseMetadataCheck -Repository 'Azure/terraform-azurerm-avm-res-example' -EventName 'merge_group' -EventPath $EventPath -SummaryPath '' -SkipModuleVersionCheck
                Should -Invoke Invoke-AvmGitHubApi -Exactly 1 -ParameterFilter { $Endpoint -eq 'repos/Azure/terraform-azurerm-avm-res-example/pulls/7' }
            }

            $probe.PullRequest | Should -Be 7
            $probe.EventName | Should -Be 'merge_group'
            $probe.Status | Should -Be 'fail'
            @($probe.Issues.Code) | Should -Be @('conflicting-labels')
        }

        It 'uses PullRequestNumber without reading an event file' {
            $responses = New-ReleaseMetadataApi -Number 9 -Labels 'patch'

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Write-AvmLog -MockWith { }
                Invoke-AvmReleaseMetadataCheck -Repository 'Azure/terraform-azurerm-avm-res-example' -EventName 'workflow_dispatch' -EventPath '' -PullRequestNumber 9 -SummaryPath '' -SkipModuleVersionCheck
            }

            $probe.PullRequest | Should -Be 9
            $probe.Status | Should -Be 'pass'
        }

        It 'rejects <Case>' -TestCases @(
            @{ Case = 'an event without a pull request'; EventName = 'push'; Payload = @{ ref = 'refs/heads/main' }; Message = "Event 'push' does not identify a pull request" }
            @{ Case = 'a merge group head ref without a pull request'; EventName = 'merge_group'; Payload = @{ merge_group = @{ head_ref = 'refs/heads/main' } }; Message = "head ref 'refs/heads/main' does not name a pull request" }
            @{ Case = 'a pull_request event without a number'; EventName = 'pull_request'; Payload = @{ pull_request = @{ title = 'x' } }; Message = 'has no pull request number' }
            @{ Case = 'a missing event file'; EventName = 'pull_request'; Payload = $null; Message = 'does not exist' }
        ) {
            param($Case, $EventName, $Payload, $Message)
            $path = Join-Path $TestDrive "missing-$([guid]::NewGuid().ToString('N')).json"
            if ($null -ne $Payload) {
                $path = $eventPath
                $Payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
            }

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ EventName = $EventName; EventPath = $path } {
                param([string] $EventName, [string] $EventPath)
                Mock Invoke-AvmGitHubApi -MockWith { throw [System.InvalidOperationException]::new('GitHub must not be called.') }
                try {
                    Invoke-AvmReleaseMetadataCheck -Repository 'Azure/terraform-azurerm-avm-res-example' -EventName $EventName -EventPath $EventPath -SummaryPath '' -SkipModuleVersionCheck
                }
                catch {
                    $_.Exception
                }
            }

            $probe | Should -BeOfType ([System.ArgumentException])
            $probe.Message | Should -Match $Message
        }

        It 'rejects a repository that is not owner/name' {
            { Invoke-AvmReleaseMetadataCheck -Repository 'not-a-repository' -PullRequestNumber 1 -SummaryPath '' -SkipModuleVersionCheck } |
                Should -Throw -ExceptionType ([System.ArgumentException]) -ExpectedMessage "*must be 'owner/name'*"
        }
    }

    Context 'reading the facts' {
        It 'reads every page of changed files' {
            $files = @(1..101 | ForEach-Object { New-ReleaseMetadataFile "examples/e$_/main.tf" })
            $responses = New-ReleaseMetadataApi -Author 'dependabot[bot]' -Title 'chore(deps): bump' -Files $files

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Write-AvmLog -MockWith { }
                $facts = Get-AvmReleaseMetadataFacts -Repository 'Azure/terraform-azurerm-avm-res-example' -Number 42
                Should -Invoke Invoke-AvmGitHubApi -Exactly 2 -ParameterFilter { $Endpoint -like '*/pulls/42/files*' }
                $facts
            }

            @($probe.ChangedFiles).Count | Should -Be 101
            $probe.ChangedFiles[100].Path | Should -Be 'examples/e101/main.tf'
        }

        It 'treats an incomplete file list as unknown, so a bot pull request needs a label' {
            $responses = New-ReleaseMetadataApi -Author 'dependabot[bot]' -Title 'chore(deps): bump' -Files @(New-ReleaseMetadataFile 'examples/default/main.tf') -ChangedFiles 3

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Write-AvmLog -MockWith { }
                $facts = Get-AvmReleaseMetadataFacts -Repository 'Azure/terraform-azurerm-avm-res-example' -Number 42
                Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'listed 1 of 3 changed files' }
                $facts
            }

            $probe.ChangedFiles | Should -BeNullOrEmpty
        }

        It 'records the last person or app that added each version label on a bot pull request' {
            $events = @(
                @{ event = 'labeled'; label = @{ name = 'patch' }; actor = @{ login = 'github-actions[bot]' } }
                @{ event = 'unlabeled'; label = @{ name = 'patch' }; actor = @{ login = 'alice' } }
                @{ event = 'labeled'; label = @{ name = 'Patch' }; actor = @{ login = 'alice' } }
                @{ event = 'labeled'; label = @{ name = 'dependencies' }; actor = @{ login = 'dependabot[bot]' } }
                @{ event = 'review_requested'; actor = @{ login = 'bob' } }
            )
            $responses = New-ReleaseMetadataApi -Author 'dependabot[bot]' -Title 'chore(deps): bump' -Labels 'patch', 'dependencies', 'minor' -Events $events -Files @(New-ReleaseMetadataFile 'examples/default/main.tf')

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Get-AvmReleaseMetadataFacts -Repository 'Azure/terraform-azurerm-avm-res-example' -Number 42
            }

            $added = @{}
            foreach ($label in $probe.Labels) {
                $added[$label.Name] = $label.AddedBy
            }
            $added['patch'] | Should -Be 'alice'
            $added['dependencies'] | Should -Be 'dependabot[bot]'
            $added['minor'] | Should -BeNullOrEmpty
        }

        It 'does not read label events for a human pull request' {
            $responses = New-ReleaseMetadataApi -Labels 'patch'
            $responses.Remove('repos/Azure/terraform-azurerm-avm-res-example/issues/42/events?per_page=100&page=1')

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Get-AvmReleaseMetadataFacts -Repository 'Azure/terraform-azurerm-avm-res-example' -Number 42
                Should -Invoke Invoke-AvmGitHubApi -Exactly 0 -ParameterFilter { $Endpoint -like '*/events*' }
            }

            $probe.Labels[0].AddedBy | Should -BeNullOrEmpty
        }

        It 'picks the highest vMAJOR.MINOR.PATCH tag as the current version' {
            $responses = New-ReleaseMetadataApi -Tags 'v0.9.3', 'v0.10.0', 'v0.2.0', 'v1.0.0-beta', 'v01.2.3', 'release'

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Get-AvmReleaseMetadataFacts -Repository 'Azure/terraform-azurerm-avm-res-example' -Number 42
            }

            $probe.CurrentVersion | Should -Be 'v0.10.0'
        }

        It 'returns no current version when the repository has no version tags' {
            $responses = New-ReleaseMetadataApi
            $responses['repos/Azure/terraform-azurerm-avm-res-example/git/matching-refs/tags/v'] = $null

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Get-AvmReleaseMetadataFacts -Repository 'Azure/terraform-azurerm-avm-res-example' -Number 42
            }

            $probe.CurrentVersion | Should -BeNullOrEmpty
        }
    }

    Context 'formatting-only bot changes' {
        It 'compares each module file at the merge base and the head and passes when all are formatting only' {
            $responses = New-ReleaseMetadataApi -Author 'dependabot[bot]' -Title 'chore(deps): bump' -Files @(
                New-ReleaseMetadataFile 'main.tf'
                New-ReleaseMetadataFile 'modules/child/main.tf'
                New-ReleaseMetadataFile 'README.md'
            )
            $repo = 'repos/Azure/terraform-azurerm-avm-res-example'
            $responses["$repo/contents/main.tf?ref=merge-base-sha"] = New-ReleaseMetadataContent "locals {`n  a=1`n}`n"
            $responses["$repo/contents/main.tf?ref=head-sha"] = New-ReleaseMetadataContent "locals {`n  a = 1`n}`n"
            $responses["$repo/contents/modules/child/main.tf?ref=merge-base-sha"] = New-ReleaseMetadataContent 'base'
            $responses["$repo/contents/modules/child/main.tf?ref=head-sha"] = New-ReleaseMetadataContent 'head'

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Test-AvmReleaseFormatEquivalence -MockWith { $true }
                Mock Write-AvmLog -MockWith { }
                $result = Invoke-AvmReleaseMetadataCheck -Repository 'Azure/terraform-azurerm-avm-res-example' -PullRequestNumber 42 -SummaryPath '' -SkipModuleVersionCheck
                Should -Invoke Test-AvmReleaseFormatEquivalence -Exactly 1 -ParameterFilter { $Path -eq 'main.tf' -and $BaseContent -ceq "locals {`n  a=1`n}`n" -and $HeadContent -ceq "locals {`n  a = 1`n}`n" }
                Should -Invoke Test-AvmReleaseFormatEquivalence -Exactly 1 -ParameterFilter { $Path -eq 'modules/child/main.tf' -and $BaseContent -eq 'base' -and $HeadContent -eq 'head' }
                Should -Invoke Test-AvmReleaseFormatEquivalence -Exactly 0 -ParameterFilter { $Path -eq 'README.md' }
                Should -Invoke Invoke-AvmGitHubApi -Exactly 4 -ParameterFilter { $Endpoint -like '*/contents/*' -and $AllowNotFound }
                $result
            }

            $probe.Status | Should -Be 'pass'
            $probe.FormattingOnly | Should -BeTrue
            $probe.TriggersRelease | Should -BeFalse
        }

        It 'stops at the first module file that changes beyond formatting and fails without a label' {
            $responses = New-ReleaseMetadataApi -Author 'dependabot[bot]' -Title 'chore(deps): bump' -Files @(
                New-ReleaseMetadataFile 'main.tf'
                New-ReleaseMetadataFile 'variables.tf'
            )
            $repo = 'repos/Azure/terraform-azurerm-avm-res-example'
            foreach ($path in 'main.tf', 'variables.tf') {
                foreach ($ref in 'merge-base-sha', 'head-sha') {
                    $responses["$repo/contents/$($path)?ref=$ref"] = New-ReleaseMetadataContent "$path $ref"
                }
            }

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Test-AvmReleaseFormatEquivalence -MockWith { $false }
                Mock Write-AvmLog -MockWith { }
                $result = Invoke-AvmReleaseMetadataCheck -Repository 'Azure/terraform-azurerm-avm-res-example' -PullRequestNumber 42 -SummaryPath '' -SkipModuleVersionCheck
                Should -Invoke Test-AvmReleaseFormatEquivalence -Exactly 1
                Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter { $Level -eq 'Error' -and $Message -match 'needs a version label' }
                $result
            }

            $probe.Status | Should -Be 'fail'
            @($probe.Issues.Code) | Should -Be @('missing-label')
            @($probe.ModuleCodeFiles) | Should -Be @('main.tf', 'variables.tf')
        }

        It 'treats content GitHub cannot return as base64 as unknown' {
            $responses = New-ReleaseMetadataApi -Author 'dependabot[bot]' -Title 'chore(deps): bump' -Files @(New-ReleaseMetadataFile 'main.tf')
            $repo = 'repos/Azure/terraform-azurerm-avm-res-example'
            $responses["$repo/contents/main.tf?ref=merge-base-sha"] = @{ encoding = 'none'; content = '' }
            $responses["$repo/contents/main.tf?ref=head-sha"] = $null

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Test-AvmReleaseFormatEquivalence -MockWith { $null -ne $BaseContent -and $null -ne $HeadContent }
                Get-AvmReleaseMetadataFacts -Repository 'Azure/terraform-azurerm-avm-res-example' -Number 42
                Should -Invoke Test-AvmReleaseFormatEquivalence -Exactly 1 -ParameterFilter { $null -eq $BaseContent -and $null -eq $HeadContent }
            }

            $probe.ChangedFiles[0].FormatEquivalent | Should -BeFalse
        }

        It 'skips the content comparison when a module file is <Status>' -TestCases @(
            @{ Status = 'added' }
            @{ Status = 'removed' }
            @{ Status = 'renamed' }
        ) {
            param($Status)
            $responses = New-ReleaseMetadataApi -Author 'dependabot[bot]' -Title 'chore(deps): bump' -Files @(
                New-ReleaseMetadataFile 'main.tf'
                New-ReleaseMetadataFile 'outputs.tf' -Status $Status -PreviousPath $(if ($Status -eq 'renamed') { 'main.outputs.tf' })
            )

            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Test-AvmReleaseFormatEquivalence -MockWith { $true }
                Mock Write-AvmLog -MockWith { }
                $result = Invoke-AvmReleaseMetadataCheck -Repository 'Azure/terraform-azurerm-avm-res-example' -PullRequestNumber 42 -SummaryPath '' -SkipModuleVersionCheck
                Should -Invoke Invoke-AvmGitHubApi -Exactly 0 -ParameterFilter { $Endpoint -like '*/compare/*' -or $Endpoint -like '*/contents/*' }
                Should -Invoke Test-AvmReleaseFormatEquivalence -Exactly 0
                $result
            }

            $probe.Status | Should -Be 'fail'
            $probe.FormattingOnly | Should -BeFalse
        }

        It 'never compares content for a human pull request' {
            $responses = New-ReleaseMetadataApi -Labels 'patch' -Files @(New-ReleaseMetadataFile 'main.tf')

            InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Test-AvmReleaseFormatEquivalence -MockWith { $true }
                $null = Get-AvmReleaseMetadataFacts -Repository 'Azure/terraform-azurerm-avm-res-example' -Number 42
                Should -Invoke Test-AvmReleaseFormatEquivalence -Exactly 0
                Should -Invoke Invoke-AvmGitHubApi -Exactly 0 -ParameterFilter { $Endpoint -like '*/compare/*' }
            }
        }
    }

    Context 'reporting' {
        It 'appends a job summary that tells the author how to fix the failure' {
            $summaryPath = Join-Path $TestDrive 'summary.md'
            Set-Content -LiteralPath $summaryPath -Value "existing`n" -NoNewline -Encoding utf8NoBOM
            $responses = New-ReleaseMetadataApi -Labels 'enhancement' -Body 'No template.'

            InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses; SummaryPath = $summaryPath } {
                param([hashtable] $Responses, [string] $SummaryPath)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Write-AvmLog -MockWith { }
                $null = Invoke-AvmReleaseMetadataCheck -Repository 'Azure/terraform-azurerm-avm-res-example' -PullRequestNumber 42 -SummaryPath $SummaryPath -SkipModuleVersionCheck
                Should -Invoke Write-AvmLog -Exactly 2 -ParameterFilter { $Level -eq 'Error' }
                Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter { $Level -eq 'Info' -and $Message -match '#42 failed \(Human, version label: none\)' }
            }

            $summary = Get-Content -LiteralPath $summaryPath -Raw
            $summary | Should -BeLike "existing`n## Release metadata for #42: failed*"
            $summary | Should -Match '(?m)^- \*\*missing-label\*\*: '
            $summary | Should -Match '(?m)^- \*\*breaking-checkbox-missing\*\*: '
        }

        It 'returns a failed result without throwing' {
            $responses = New-ReleaseMetadataApi
            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Responses = $responses } {
                param([hashtable] $Responses)
                $script:releaseMetadataApi = $Responses
                Mock Invoke-AvmGitHubApi -MockWith { $script:releaseMetadataApi[$Endpoint] }
                Mock Write-AvmLog -MockWith { }
                Invoke-AvmReleaseMetadataCheck -Repository 'Azure/terraform-azurerm-avm-res-example' -PullRequestNumber 42 -SummaryPath '' -SkipModuleVersionCheck
            }

            $probe.Status | Should -Be 'fail'
            $probe.Tool | Should -Be 'release-metadata/1'
        }
    }
}
