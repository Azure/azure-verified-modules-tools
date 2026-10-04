BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:projectDriver = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Add-RepositoryItemsToProject.ps1'
    . (Join-Path (Split-Path $script:projectDriver -Parent) 'lib' 'Logging.ps1')
    . (Join-Path (Split-Path $script:projectDriver -Parent) 'lib' 'RetryHelpers.ps1')
}

Describe 'Repository project sync folded logging' -Tag Component {
    BeforeEach {
        $script:previousActions = [Environment]::GetEnvironmentVariable('GITHUB_ACTIONS')
        $env:GITHUB_ACTIONS = 'true'
        $script:projectFixture = @{
            Directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Mode = ''
            Mutations = 0
        }
        $null = New-Item -ItemType Directory -Path $script:projectFixture.Directory
        $fixture = $script:projectFixture
        Mock New-TemporaryFile ({
            New-Item -ItemType File -Path (Join-Path $fixture.Directory ([guid]::NewGuid().ToString('N')))
        }.GetNewClosure())
        Mock Invoke-GitHubCliWithRetry ({
            param($commands)
            $queryArgument = $commands[0].Arguments | Where-Object { $_ -clike 'query=@*' }
            $query = Get-Content -LiteralPath $queryArgument.Substring(7) -Raw
            if ($query -match 'addProjectV2ItemById') {
                $fixture.Mutations++
                if ($fixture.Mode -ceq 'failed-add') { return @{ success = $false; output = $null } }
                return @{ success = $true; output = @{ data = @{ addProjectV2ItemById = @{ item = @{ id = 'synthetic-project-item' } } } } }
            }
            if ($query -match 'projectV2\(number:') {
                if ($fixture.Mode -ceq 'missing-project') { return @{ success = $false; output = $null } }
                return @{ success = $true; output = @{ data = @{ organization = @{ projectV2 = @{ id = 'synthetic-project'; title = 'Fixture project' } } } } }
            }
            if ($query -notmatch 'orderBy: \{ field: UPDATED_AT') { throw 'Unexpected project query in isolated test.' }
            $collection = $query -match '\bissues\(states:' ? 'issues' : 'pullRequests'
            $memberships = $collection -ceq 'issues' ? @() : @(@{ project = @{ number = 1011 } })
            return @{
                success = $true
                output = @{ data = @{
                    rateLimit = @{ remaining = 4000 }
                    repository = @{ $collection = @{
                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                        nodes = @(@{
                            id = 'synthetic-content'; number = 7; updatedAt = [datetime]::UtcNow.ToString('o')
                            projectItems = @{ nodes = $memberships }
                        })
                    } }
                } }
            }
        }.GetNewClosure())
        Mock Invoke-RepositorySyncProcess { throw 'External project process forbidden in isolated test.' }
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', ($null -eq $script:previousActions ? [NullString]::Value : $script:previousActions), 'Process')
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'keeps detail folded and reports accurate counts for plan-only <PlanOnly>' -ForEach @(
        @{ PlanOnly = $true }, @{ PlanOnly = $false }
    ) {
        $records = @(& $script:projectDriver -planOnly $PlanOnly -outputDirectory $script:projectFixture.Directory 6>&1)
        $messages = @($records | ForEach-Object { $_.MessageData.ToString() })
        $messages[0] | Should -Match '^Project sync: Azure/terraform-azurerm-avm-ptn-example-repo'
        $messages[1] | Should -Be '::group::Project lookups and item updates'
        $messages[-2] | Should -Be '::endgroup::'
        $messages[-1] | Should -Match '^Project sync completed.*found: 2; already on project: 1;.*GraphQL budget remaining: 4000'
        $messages[-1] | Should -Match ($PlanOnly ? 'would add: 1' : 'added: 1; failed: 0')
        $script:projectFixture.Mutations | Should -Be ($PlanOnly ? 0 : 1)
    }

    It 'keeps diagnostic text but omits group commands outside Actions' {
        [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', [NullString]::Value, 'Process')
        $records = @(& $script:projectDriver -planOnly $true -outputDirectory $script:projectFixture.Directory 6>&1)
        $text = $records.MessageData | Out-String
        $text | Should -Not -Match '::group::|::endgroup::'
        $text | Should -Match 'Resolved project'
        $text | Should -Match 'would add'
        $script:projectFixture.Mutations | Should -Be 0
    }

    It 'closes a failed group before surfacing project-resolution errors and persists the failure' {
        $script:projectFixture.Mode = 'missing-project'
        $records = [System.Collections.Generic.List[object]]::new()
        { & $script:projectDriver -outputDirectory $script:projectFixture.Directory 6>&1 | ForEach-Object { $records.Add($_) } } |
            Should -Throw '*Could not resolve ProjectV2*'
        $records[-1].MessageData.ToString() | Should -Be '::endgroup::'
        ($records.MessageData | Out-String) | Should -Not -Match 'Project sync completed'
        $issue = Get-Content -LiteralPath (Join-Path $script:projectFixture.Directory 'project-sync.log.json') -Raw | ConvertFrom-Json
        $issue.severity | Should -Be 'error'
        $script:projectFixture.Mutations | Should -Be 0
    }

    It 'repeats failed item warnings outside folded details instead of hiding them in a successful summary' {
        $script:projectFixture.Mode = 'failed-add'
        $records = @(& $script:projectDriver -outputDirectory $script:projectFixture.Directory 3>&1 6>&1)
        $records[-1] | Should -BeOfType ([System.Management.Automation.WarningRecord])
        $records[-1].Message | Should -Match 'Failed to add'
        $records[-2].MessageData.ToString() | Should -Match 'added: 0; failed: 1'
        $script:projectFixture.Mutations | Should -Be 1
    }
}
