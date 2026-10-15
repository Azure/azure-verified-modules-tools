BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $labelsRoot = Join-Path $root 'repository-management' 'labels'
    . (Join-Path $labelsRoot 'scripts' 'LabelCatalog.ps1')
    . (Join-Path $labelsRoot 'scripts' 'LabelSync.ps1')
    . (Join-Path $labelsRoot 'scripts' 'LabelPublication.ps1')
    $script:catalogPath = Join-Path $labelsRoot 'avm-standard-github-labels.json'
    $script:labels = @(Read-AvmStandardGitHubLabels -Path $script:catalogPath)
}

Describe 'Standard GitHub label catalog' {
    It 'preserves all 45 labels and their published descriptions' {
        $script:labels | Should -HaveCount 45
        $owner = @($script:labels | Where-Object Name -eq 'Needs: Module Owner :mega:')
        $owner | Should -HaveCount 1
        $owner[0].Description | Should -Match 'In the BRM repository:'
        $owner[0].GitHubDescription | Should -BeExactly 'This module needs an owner to develop or maintain it'
        $script:labels[-1].Name | Should -BeExactly 'Class: Child Module :package:'
    }

    It 'renders the published CSV schema and all 45 rows with LF endings' {
        $csv = ConvertTo-AvmStandardGitHubLabelsCsv -Labels $script:labels
        $csv | Should -Match '^Name,Description,HEX'
        $csv | Should -Not -Match "`r"
        $csv.EndsWith("`n") | Should -BeTrue
        $rows = @($csv | ConvertFrom-Csv)
        $rows | Should -HaveCount 45
        for ($index = 0; $index -lt $rows.Count; $index++) {
            $rows[$index].Name | Should -BeExactly $script:labels[$index].Name
            $rows[$index].Description | Should -BeExactly $script:labels[$index].Description
            $rows[$index].HEX | Should -BeExactly $script:labels[$index].Color
        }
        (ConvertTo-AvmStandardGitHubLabelsCsv -Labels $script:labels) | Should -BeExactly $csv
    }

    It 'rejects an empty catalog or unrecognized fields' {
        $path = Join-Path $TestDrive 'invalid-labels.json'
        [System.IO.File]::WriteAllText($path, '{"labels":[]}')
        { Read-AvmStandardGitHubLabels -Path $path } | Should -Throw
        [System.IO.File]::WriteAllText($path, '{"labels":[{"name":"test","description":"valid","color":"123456","extra":"x"}]}')
        { Read-AvmStandardGitHubLabels -Path $path } | Should -Throw
    }

    It 'rejects duplicate names and malformed colors' {
        $path = Join-Path $TestDrive 'invalid-labels.json'
        [System.IO.File]::WriteAllText($path, '{"labels":[{"name":"Test","description":"one","color":"123456"},{"name":"test","description":"two","color":"ABCDEF"}]}')
        { Read-AvmStandardGitHubLabels -Path $path } | Should -Throw
        [System.IO.File]::WriteAllText($path, '{"labels":[{"name":"test","description":"valid","color":"not-hex"}]}')
        { Read-AvmStandardGitHubLabels -Path $path } | Should -Throw
    }

    It 'requires a GitHub-safe description when documentation text exceeds 100 characters' {
        $path = Join-Path $TestDrive 'invalid-labels.json'
        $tooLong = 'x' * 101
        [System.IO.File]::WriteAllText($path, (
                @{ labels = @(@{ name = 'test'; description = $tooLong; color = '123456' }) } |
                    ConvertTo-Json -Depth 5
            ))
        { Read-AvmStandardGitHubLabels -Path $path } | Should -Throw
        [System.IO.File]::WriteAllText($path, (
                @{ labels = @(@{ name = 'test'; description = $tooLong; githubDescription = 'short'; color = '123456' }) } |
                    ConvertTo-Json -Depth 5
            ))
        $result = @(Read-AvmStandardGitHubLabels -Path $path)
        $result | Should -HaveCount 1
        $result[0].GitHubDescription | Should -BeExactly 'short'
    }

    It 'rejects publishing an empty CSV' {
        { ConvertTo-AvmStandardGitHubLabelsCsv -Labels @() } | Should -Throw
    }

    It 'treats the existing quoted CSV and generated JSON as the same data' {
        $published = '"Name","Description","HEX"' + "`n" +
            '"Test","Test label","123456"' + "`n"
        $generated = "Name,Description,HEX`nTest,Test label,123456`n"
        (Test-AvmStandardGitHubLabelsCsvMatches -Published $published -Generated $generated) |
            Should -BeTrue
        (Test-AvmStandardGitHubLabelsCsvMatches -Published $published `
                -Generated "Name,Description,HEX`nTest,Other label,123456`n") |
            Should -BeFalse
    }
}

Describe 'Standard GitHub label reconciliation' {
    It 'creates missing standard labels without touching custom labels' {
        $existing = @(
            [pscustomobject]@{
                name = $script:labels[0].Name; color = $script:labels[0].Color
                description = $script:labels[0].GitHubDescription
            }
            [pscustomobject]@{ name = 'Custom'; color = 'abcdef'; description = 'Keep me' }
        )
        $changes = @(Get-AvmStandardGitHubLabelChanges -Labels $script:labels[0..1] -ExistingLabels $existing)
        $changes | Should -HaveCount 1
        $changes[0].Action | Should -BeExactly 'Create'
        $changes[0].Label.Name | Should -BeExactly $script:labels[1].Name
    }

    It 'updates only changed colors or GitHub descriptions' {
        $label = $script:labels[7]
        $existing = @([pscustomobject]@{ name = $label.Name; color = $label.Color; description = 'old' })
        $changes = @(Get-AvmStandardGitHubLabelChanges -Labels @($label) -ExistingLabels $existing)
        $changes | Should -HaveCount 1
        $changes[0].Action | Should -BeExactly 'Update'
        $changes[0].Label.GitHubDescription | Should -BeExactly 'This module needs an owner to develop or maintain it'
        $existing[0].description = $label.GitHubDescription
        @(Get-AvmStandardGitHubLabelChanges -Labels @($label) -ExistingLabels $existing) | Should -HaveCount 0
        $existing[0].color = '123456'
        @(Get-AvmStandardGitHubLabelChanges -Labels @($label) -ExistingLabels $existing) | Should -HaveCount 1
    }

    It 'rejects invalid GitHub responses instead of creating every label' {
        $existing = @([pscustomobject]@{ color = '123456'; description = 'no name' })
        { Get-AvmStandardGitHubLabelChanges -Labels @($script:labels[0]) -ExistingLabels $existing } |
            Should -Throw
    }
}

Describe 'Standard GitHub label synchronization flow' {
    BeforeEach {
        $script:source = @($script:labels[0], $script:labels[7])
        $script:live = @(
            [pscustomobject]@{
                name = $script:source[0].Name; description = $script:source[0].GitHubDescription
                color = $script:source[0].Color
            }
            [pscustomobject]@{ name = 'Custom'; description = 'Keep me'; color = '123456' }
        )
        $script:labelCalls = [System.Collections.Generic.List[object]]::new()
        $script:updateLive = $true
        Mock Invoke-AvmStandardLabelProcess {
            $script:labelCalls.Add([pscustomobject]@{
                    Command = $ArgumentList[1]; Arguments = @($ArgumentList)
                })
            if ($ArgumentList[1] -eq 'list') {
                return [pscustomobject]@{
                    StdOut = ConvertTo-Json -InputObject @($script:live) -Depth 5 -Compress
                }
            }
            if ($ArgumentList[1] -ne 'create') {
                throw "Unexpected label command: $($ArgumentList -join ' ')"
            }
            if ($script:updateLive) {
                $name = $ArgumentList[2]
                $script:live = @($script:live | Where-Object { $_.name -cne $name })
                $script:live += [pscustomobject]@{
                    name = $name
                    description = $ArgumentList[([array]::IndexOf($ArgumentList, '--description') + 1)]
                    color = $ArgumentList[([array]::IndexOf($ArgumentList, '--color') + 1)]
                }
            }
            [pscustomobject]@{ StdOut = 'created' }
        }
    }

    It 'plans missing labels without writing or removing repository-specific labels' {
        $result = @(Invoke-AvmStandardGitHubLabelSync -Labels $script:source `
                -GitHubPath 'gh' -Repositories @('Azure/Azure-Verified-Modules'))
        $result -join "`n" | Should -Match 'needs 1 label change'
        $result -join "`n" | Should -Match 'Create: Needs: Module Owner'
        $script:labelCalls | Should -HaveCount 1
        $script:live | Should -HaveCount 2
    }

    It 'upserts the GitHub-safe description and verifies the resulting labels' {
        $null = @(Invoke-AvmStandardGitHubLabelSync -Labels $script:source `
                -GitHubPath 'gh' -Repositories @('Azure/Azure-Verified-Modules') -Apply -Confirm:$false)
        $script:labelCalls | Should -HaveCount 3
        $created = @($script:labelCalls | Where-Object Command -eq 'create')[0].Arguments
        $created | Should -Contain 'This module needs an owner to develop or maintain it'
        @($script:live | Where-Object name -eq 'Custom') | Should -HaveCount 1
        @(Invoke-AvmStandardGitHubLabelSync -Labels $script:source `
                -GitHubPath 'gh' -Repositories @('Azure/Azure-Verified-Modules'))[-1] |
            Should -Match 'needs 0 label change'
    }

    It 'fails if a GitHub update does not produce the expected state' {
        $script:updateLive = $false
        { Invoke-AvmStandardGitHubLabelSync -Labels $script:source `
                -GitHubPath 'gh' -Repositories @('Azure/Azure-Verified-Modules') -Apply -Confirm:$false } |
            Should -Throw
    }

    It 'refuses an empty GitHub response instead of creating every label' {
        $script:live = @()
        { Invoke-AvmStandardGitHubLabelSync -Labels $script:source `
                -GitHubPath 'gh' -Repositories @('Azure/Azure-Verified-Modules') -Apply -Confirm:$false } |
            Should -Throw
        $script:labelCalls | Should -HaveCount 1
    }
}

Describe 'Generated-label publication candidate' {
    BeforeEach {
        $script:bot = 'azure-verified-modules[bot]'
        $script:repository = 'Azure/Azure-Verified-Modules'
        $script:csvPath = 'docs/static/governance/avm-standard-github-labels.csv'
        $script:pullRequest = @{
            user = @{ login = $script:bot }
            head = @{ ref = 'automation/avm-labels-123-1'; repo = @{ full_name = $script:repository } }
            base = @{ ref = 'main' }
        }
        $script:files = @(@{ filename = $script:csvPath })
        $script:commits = @(@{ author = @{ login = $script:bot } })
    }

    It 'allows only an app-owned, single-file publication' {
        { Assert-AvmStandardLabelPublicationCandidate -PullRequest $script:pullRequest `
                -Files $script:files -Commits $script:commits -Repository $script:repository `
                -Path $script:csvPath -BotLogin $script:bot } | Should -Not -Throw
    }

    It 'refuses to overwrite human edits' {
        $script:commits[0].author.login = 'human'
        { Assert-AvmStandardLabelPublicationCandidate -PullRequest $script:pullRequest `
                -Files $script:files -Commits $script:commits -Repository $script:repository `
                -Path $script:csvPath -BotLogin $script:bot } | Should -Throw
    }

    It 'refuses an unexpected changed file' {
        $script:files = @(@{ filename = 'README.md' })
        { Assert-AvmStandardLabelPublicationCandidate -PullRequest $script:pullRequest `
                -Files $script:files -Commits $script:commits -Repository $script:repository `
                -Path $script:csvPath -BotLogin $script:bot } | Should -Throw
    }
}

Describe 'Generated-label API pagination' {
    It 'flattens multiple pages into individual records' {
        $records = @(ConvertFrom-AvmLabelApiPages -Json '[[{"filename":"first"}],[{"filename":"second"}]]')
        $records | Should -HaveCount 2
        $records[0]['filename'] | Should -BeExactly 'first'
        $records[1]['filename'] | Should -BeExactly 'second'
    }

    It 'rejects responses that are not arrays of records' {
        { ConvertFrom-AvmLabelApiPages -Json '{"filename":"wrong"}' } | Should -Throw
        { ConvertFrom-AvmLabelApiPages -Json '[[42]]' } | Should -Throw
    }
}

Describe 'Generated-label publication flow' {
    BeforeEach {
        $script:sha = 'a' * 40
        $script:csv = "Name,Description,HEX`nTest,Test label,123456`n"
        $script:repo = 'Azure/Azure-Verified-Modules'
        $script:path = 'docs/static/governance/avm-standard-github-labels.csv'
        $script:responses = @{}
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(
                "Name,Description,HEX`nOld,Old label,000000`n"
            ))
        $script:responses["GET repos/$($script:repo)/contents/$($script:path)?ref=main"] = (
            @{ sha = $script:sha; content = $base64 } | ConvertTo-Json -Compress
        )
        Mock Invoke-AvmStandardLabelProcess {
            $endpoint = @($ArgumentList | Where-Object { $_ -like 'repos/*' })[0]
            $method = if ($ArgumentList -contains 'PUT') { 'PUT' }
            elseif ($ArgumentList -contains 'POST') { 'POST' }
            else { 'GET' }
            $key = "$method $endpoint"
            $script:calls.Add([pscustomobject]@{ Key = $key; Arguments = @($ArgumentList) })
            if (-not $script:responses.ContainsKey($key)) {
                throw "Unexpected GitHub request: $key"
            }
            [pscustomobject]@{ StdOut = $script:responses[$key] }
        }
    }

    It 'previews a changed CSV without any remote writes' {
        $output = @(Invoke-AvmStandardGitHubLabelsPublication -GitHubPath 'gh' -Csv $script:csv)
        $output[-1] | Should -Match 'differs'
        $script:calls | Should -HaveCount 1
    }

    It 'does nothing when main already contains the generated CSV' {
        $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($script:csv))
        $script:responses["GET repos/$($script:repo)/contents/$($script:path)?ref=main"] = (
            @{ sha = $script:sha; content = $base64 } | ConvertTo-Json -Compress
        )
        $output = @(Invoke-AvmStandardGitHubLabelsPublication -GitHubPath 'gh' -Csv $script:csv `
                -Publish -Confirm:$false)
        $output[-1] | Should -Match 'already matches'
        $script:calls | Should -HaveCount 1
    }

    It 'opens a scoped publication change on a new branch' {
        $script:responses["GET repos/$($script:repo)/pulls?state=open&base=main&per_page=100"] = '[[]]'
        $script:responses["GET repos/$($script:repo)/git/ref/heads/main"] = (
            @{ object = @{ sha = $script:sha } } | ConvertTo-Json -Depth 3 -Compress
        )
        $script:responses["POST repos/$($script:repo)/git/refs"] = '{}'
        $script:responses["PUT repos/$($script:repo)/contents/$($script:path)"] = '{}'
        $script:responses["POST repos/$($script:repo)/pulls"] = (
            @{ html_url = "https://github.com/$($script:repo)/pull/1" } | ConvertTo-Json -Compress
        )
        $output = @(Invoke-AvmStandardGitHubLabelsPublication -GitHubPath 'gh' -Csv $script:csv `
                -Publish -BotLogin 'azure-verified-modules[bot]' -RunId '123' -RunAttempt '1' `
                -SourceSha $script:sha -Confirm:$false)
        $output[-1] | Should -Match 'https://github.com/Azure/Azure-Verified-Modules/pull/1'
        $script:calls | Should -HaveCount 6
        $put = @($script:calls | Where-Object Key -eq "PUT repos/$($script:repo)/contents/$($script:path)")[0]
        $payload = @($put.Arguments | Where-Object { $_ -like 'content=*' })[0].Substring(8)
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
            Should -BeExactly $script:csv
    }

    It 'updates only an existing bot-owned, single-file publication' {
        $candidate = @{
            number = 12; user = @{ login = 'azure-verified-modules[bot]' }
            head = @{ ref = 'automation/avm-labels-123-1'; repo = @{ full_name = $script:repo } }
            base = @{ ref = 'main' }; html_url = "https://github.com/$($script:repo)/pull/12"
        }
        $script:responses["GET repos/$($script:repo)/pulls?state=open&base=main&per_page=100"] = (
            '[' + (ConvertTo-Json -InputObject @($candidate) -Depth 5 -Compress) + ']'
        )
        $script:responses["GET repos/$($script:repo)/pulls/12/files?per_page=100"] = (
            '[' + (ConvertTo-Json -InputObject @(@{ filename = $script:path }) -Depth 5 -Compress) + ']'
        )
        $script:responses["GET repos/$($script:repo)/pulls/12/commits?per_page=100"] = (
            '[' + (ConvertTo-Json -InputObject @(@{ author = @{ login = 'azure-verified-modules[bot]' } }) -Depth 5 -Compress) + ']'
        )
        $branch = 'automation/avm-labels-123-1'
        $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(
                "Name,Description,HEX`nOlder,Older label,000000`n"
            ))
        $script:responses["GET repos/$($script:repo)/contents/$($script:path)?ref=$branch"] = (
            @{ sha = $script:sha; content = $base64 } | ConvertTo-Json -Compress
        )
        $script:responses["PUT repos/$($script:repo)/contents/$($script:path)"] = '{}'
        $output = @(Invoke-AvmStandardGitHubLabelsPublication -GitHubPath 'gh' -Csv $script:csv `
                -Publish -BotLogin 'azure-verified-modules[bot]' -RunId '123' -RunAttempt '1' `
                -SourceSha $script:sha -Confirm:$false)
        $output[-1] | Should -Match 'https://github.com/Azure/Azure-Verified-Modules/pull/12'
        @($script:calls | Where-Object { $_.Key -like 'POST *' }) | Should -HaveCount 0
        @($script:calls | Where-Object { $_.Key -like 'PUT *' }) | Should -HaveCount 1
    }

    It 'rejects a human-edited open publication before any write' {
        $candidate = @{
            number = 12; user = @{ login = 'azure-verified-modules[bot]' }
            head = @{ ref = 'automation/avm-labels-123-1'; repo = @{ full_name = $script:repo } }
            base = @{ ref = 'main' }; html_url = "https://github.com/$($script:repo)/pull/12"
        }
        $script:responses["GET repos/$($script:repo)/pulls?state=open&base=main&per_page=100"] = (
            '[' + (ConvertTo-Json -InputObject @($candidate) -Depth 5 -Compress) + ']'
        )
        $script:responses["GET repos/$($script:repo)/pulls/12/files?per_page=100"] = (
            '[' + (ConvertTo-Json -InputObject @(@{ filename = $script:path }) -Depth 5 -Compress) + ']'
        )
        $script:responses["GET repos/$($script:repo)/pulls/12/commits?per_page=100"] = (
            '[' + (ConvertTo-Json -InputObject @(@{ author = @{ login = 'human' } }) -Depth 5 -Compress) + ']'
        )
        { Invoke-AvmStandardGitHubLabelsPublication -GitHubPath 'gh' -Csv $script:csv `
                -Publish -BotLogin 'azure-verified-modules[bot]' -RunId '123' -RunAttempt '1' `
                -SourceSha $script:sha -Confirm:$false } | Should -Throw
        @($script:calls | Where-Object { $_.Key -like 'POST *' -or $_.Key -like 'PUT *' }) |
            Should -HaveCount 0
    }
}

Describe 'Local Terraform label source' {
    It 'reads the canonical JSON directly without downloading a CSV' {
        $terraformRoot = Join-Path $root 'repository-management' 'repository-sync' 'terraform'
        $variables = Get-Content -Raw (Join-Path $terraformRoot 'variables.tf')
        $locals = Get-Content -Raw (Join-Path $terraformRoot 'locals.tf')
        $workflow = Get-Content -Raw (Join-Path $root '.github' 'workflows' 'repository-management-sync.yml')
        $reusableWorkflow = Get-Content -Raw (Join-Path $root '.github' 'workflows' 'repository-management-sync-repository.yml')
        $variables | Should -Match '\.\./\.\./labels/avm-standard-github-labels\.json'
        $locals | Should -Match 'jsondecode\(file\(var\.github_labels_source_path\)\)\.labels'
        $locals | Should -Match 'try\(label\.githubDescription, label\.description\)'
        $workflow | Should -Not -Match 'Get-AvmLabels\.ps1'
        $reusableWorkflow | Should -Not -Match 'Get-AvmLabels\.ps1'
        Test-Path -LiteralPath (Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'Get-AvmLabels.ps1') |
            Should -BeFalse
    }

    It 'restricts the central workflow to trusted main and scoped repository tokens' {
        $workflow = Get-Content -Raw (Join-Path $root '.github' 'workflows' 'repository-management-label-sync.yml')
        $workflow | Should -Match "github.ref == 'refs/heads/main'"
        $workflow | Should -Match "github.repository == 'Azure/azure-verified-modules-tools'"
        $workflow | Should -Match 'permission-issues: write'
        $workflow | Should -Match 'permission-pull-requests: write'
        $workflow | Should -Match 'plan_only:'
        $workflow | Should -Match 'default: true'
        $workflow | Should -Match 'persist-credentials: false'
    }
}
