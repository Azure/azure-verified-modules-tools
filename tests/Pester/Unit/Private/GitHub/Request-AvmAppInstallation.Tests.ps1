#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    function ConvertTo-TestContentResponse {
        param([string[]] $Repositories, [string] $Sha = 'blob-sha')
        $text = (@('repository_selection: selected', 'repositories:') + @($Repositories | ForEach-Object { "  - $_" }) + '') -join "`n"
        @{ content = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($text)); sha = $Sha }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Request-AvmAppInstallation' {
    BeforeEach {
        $script:request = @{
            Repository = 'terraform-azure-avm-res-network-virtualnetwork'
            ModuleName = 'avm-res-network-virtualnetwork'
        }
    }

    It 'reports installed when every configuration lists the repository' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Request = $script:request; Listed = (ConvertTo-TestContentResponse -Repositories @('terraform-azure-avm-res-network-virtualnetwork')) } {
            param($Request, $Listed)
            Mock Invoke-AvmGitHubApi -MockWith ({ $Listed }.GetNewClosure()) -ParameterFilter { $Endpoint -like 'repos/microsoft/github-operations/contents/*' }
            Mock Invoke-AvmGitHubApi { throw "Unexpected call: $Method $Endpoint" }
            Request-AvmAppInstallation @Request -Confirm:$false
        }

        $result.Status | Should -Be 'installed'
        $result.PullRequest | Should -BeNullOrEmpty
    }

    It 'reuses an open pull request that names the module' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Request = $script:request; Unlisted = (ConvertTo-TestContentResponse -Repositories @('other')) } {
            param($Request, $Unlisted)
            Mock Invoke-AvmGitHubApi -MockWith ({ $Unlisted }.GetNewClosure()) -ParameterFilter { $Endpoint -like 'repos/microsoft/github-operations/contents/*' }
            Mock Invoke-AvmGitHubApi {
                @{ items = @(
                        @{ title = 'chore: app install avm avm-res-network-virtualnetworkgateway'; body = ''; html_url = 'https://example.invalid/1' }
                        @{ title = 'chore: app install avm avm-res-network-virtualnetwork'; body = ''; html_url = 'https://example.invalid/2' }
                    )
                }
            } -ParameterFilter { $Endpoint -like 'search/issues*' }
            Mock Invoke-AvmGitHubApi { throw "Unexpected call: $Method $Endpoint" }
            Request-AvmAppInstallation @Request -Confirm:$false
            Should -Invoke Invoke-AvmGitHubApi -Exactly 1 -ParameterFilter {
                $Endpoint -like 'search/issues*' -and
                [uri]::UnescapeDataString($Endpoint) -like '*repo:microsoft/github-operations is:pr is:open "avm-res-network-virtualnetwork"*'
            }
        }

        $result.Status | Should -Be 'pending'
        $result.PullRequest | Should -Be 'https://example.invalid/2'
        $result.Files | Should -Be @('apps/azure/azure-verified-modules.yaml', 'apps/azure/terraform-cloud.yaml')
    }

    It 'commits only unlisted files to a fork branch and opens a pull request' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            Request  = $script:request
            Listed   = (ConvertTo-TestContentResponse -Repositories @('terraform-azure-avm-res-network-virtualnetwork'))
            Unlisted = (ConvertTo-TestContentResponse -Repositories @('a-repo', 'z-repo') -Sha 'fork-sha')
        } {
            param($Request, $Listed, $Unlisted)
            $script:refAttempts = 0
            Mock Start-Sleep {}
            Mock Invoke-AvmGitHubApi -MockWith ({ $Listed }.GetNewClosure()) -ParameterFilter {
                $Endpoint -eq 'repos/microsoft/github-operations/contents/apps/azure/azure-verified-modules.yaml?ref=main'
            }
            Mock Invoke-AvmGitHubApi -MockWith ({ $Unlisted }.GetNewClosure()) -ParameterFilter {
                $Endpoint -like '*/contents/apps/azure/terraform-cloud.yaml?ref=*'
            }
            Mock Invoke-AvmGitHubApi { @{ items = @() } } -ParameterFilter { $Endpoint -like 'search/issues*' }
            Mock Invoke-AvmGitHubApi { @{ full_name = 'someone/github-operations'; owner = @{ login = 'someone' } } } -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq 'repos/microsoft/github-operations/forks'
            }
            Mock Invoke-AvmGitHubApi { @{ object = @{ sha = 'upstream-sha' } } } -ParameterFilter {
                $Endpoint -eq 'repos/microsoft/github-operations/git/ref/heads/main'
            }
            Mock Invoke-AvmGitHubApi { $null } -ParameterFilter { $Endpoint -like 'repos/someone/github-operations/git/ref/heads/*' }
            Mock Invoke-AvmGitHubApi {
                $script:refAttempts++
                if ($script:refAttempts -eq 1) { throw [AvmGitHubException]::new('Not Found', 404) }
            } -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq 'repos/someone/github-operations/git/refs' }
            Mock Invoke-AvmGitHubApi {} -ParameterFilter { $Method -eq 'PUT' }
            Mock Invoke-AvmGitHubApi { @{ html_url = 'https://github.com/microsoft/github-operations/pull/9' } } -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq 'repos/microsoft/github-operations/pulls'
            }
            Mock Invoke-AvmGitHubApi { throw "Unexpected call: $Method $Endpoint" }

            Request-AvmAppInstallation @Request -Confirm:$false

            Should -Invoke Start-Sleep -Exactly 1
            Should -Invoke Invoke-AvmGitHubApi -Exactly 2 -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq 'repos/someone/github-operations/git/refs' -and
                $Body.ref -eq 'refs/heads/chore/app-install-avm/avm-res-network-virtualnetwork' -and $Body.sha -eq 'upstream-sha'
            }
            Should -Invoke Invoke-AvmGitHubApi -Exactly 1 -ParameterFilter { $Method -eq 'PUT' }
            Should -Invoke Invoke-AvmGitHubApi -Exactly 1 -ParameterFilter {
                $Method -eq 'PUT' -and $Endpoint -eq 'repos/someone/github-operations/contents/apps/azure/terraform-cloud.yaml' -and
                $Body.sha -eq 'fork-sha' -and $Body.branch -eq 'chore/app-install-avm/avm-res-network-virtualnetwork' -and
                $Body.message -eq 'chore: app install avm avm-res-network-virtualnetwork' -and
                [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Body.content)) -ceq (
                    "repository_selection: selected`nrepositories:`n  - a-repo`n  - terraform-azure-avm-res-network-virtualnetwork`n  - z-repo`n")
            }
            Should -Invoke Invoke-AvmGitHubApi -Exactly 1 -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq 'repos/microsoft/github-operations/pulls' -and
                $Body.head -eq 'someone:chore/app-install-avm/avm-res-network-virtualnetwork' -and $Body.base -eq 'main' -and
                $Body.title -eq 'chore: app install avm avm-res-network-virtualnetwork'
            }
        }

        $result.Status | Should -Be 'requested'
        $result.PullRequest | Should -Be 'https://github.com/microsoft/github-operations/pull/9'
        $result.Files | Should -Be @('apps/azure/terraform-cloud.yaml')
    }

    It 'reuses the existing fork, branch, and pull request from an interrupted run' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            Request  = $script:request
            Unlisted = (ConvertTo-TestContentResponse -Repositories @('other'))
            Branch   = (ConvertTo-TestContentResponse -Repositories @('terraform-azure-avm-res-network-virtualnetwork'))
        } {
            param($Request, $Unlisted, $Branch)
            Mock Invoke-AvmGitHubApi -MockWith ({ $Unlisted }.GetNewClosure()) -ParameterFilter { $Endpoint -like '*/contents/*?ref=main' }
            Mock Invoke-AvmGitHubApi -MockWith ({ $Branch }.GetNewClosure()) -ParameterFilter { $Endpoint -like 'repos/someone/*/contents/*' }
            Mock Invoke-AvmGitHubApi { @{ items = @() } } -ParameterFilter { $Endpoint -like 'search/issues*' }
            Mock Invoke-AvmGitHubApi { @{ full_name = 'someone/renamed-operations'; owner = @{ login = 'someone' } } } -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq 'repos/microsoft/github-operations/forks'
            }
            Mock Invoke-AvmGitHubApi { @{ object = @{ sha = 'sha' } } } -ParameterFilter { $Endpoint -like '*/git/ref/heads/*' }
            Mock Invoke-AvmGitHubApi { throw [AvmGitHubException]::new('A pull request already exists', 422) } -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq 'repos/microsoft/github-operations/pulls'
            }
            Mock Invoke-AvmGitHubApi { @{ html_url = 'https://example.invalid/existing' } } -ParameterFilter {
                $Endpoint -eq ('repos/microsoft/github-operations/pulls?state=open&head=' +
                    [uri]::EscapeDataString('someone:chore/app-install-avm/avm-res-network-virtualnetwork'))
            }
            Mock Invoke-AvmGitHubApi { throw "Unexpected call: $Method $Endpoint" }

            Request-AvmAppInstallation @Request -Confirm:$false
            Should -Invoke Invoke-AvmGitHubApi -Exactly 1 -ParameterFilter { $Endpoint -like 'repos/someone/renamed-operations/git/ref/heads/*' }
            Should -Invoke Invoke-AvmGitHubApi -Exactly 0 -ParameterFilter { $Method -eq 'PUT' }
            Should -Invoke Invoke-AvmGitHubApi -Exactly 0 -ParameterFilter { $Endpoint -like '*/git/refs' }
        }

        $result.Status | Should -Be 'requested'
        $result.PullRequest | Should -Be 'https://example.invalid/existing'
    }

    It 'falls back to the fork named after the operations repository when fork creation is rejected' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            Request  = $script:request
            Unlisted = (ConvertTo-TestContentResponse -Repositories @('other'))
            Branch   = (ConvertTo-TestContentResponse -Repositories @('terraform-azure-avm-res-network-virtualnetwork'))
        } {
            param($Request, $Unlisted, $Branch)
            Mock Invoke-AvmGitHubApi -MockWith ({ $Unlisted }.GetNewClosure()) -ParameterFilter { $Endpoint -like '*/contents/*?ref=main' }
            Mock Invoke-AvmGitHubApi -MockWith ({ $Branch }.GetNewClosure()) -ParameterFilter { $Endpoint -like 'repos/someone/*/contents/*' }
            Mock Invoke-AvmGitHubApi { @{ items = @() } } -ParameterFilter { $Endpoint -like 'search/issues*' }
            Mock Invoke-AvmGitHubApi { throw [AvmGitHubException]::new('Validation Failed', 422) } -ParameterFilter { $Endpoint -like '*/forks' }
            Mock Invoke-AvmGitHubApi { @{ login = 'someone' } } -ParameterFilter { $Endpoint -eq 'user' }
            Mock Invoke-AvmGitHubApi {
                @{ full_name = 'someone/github-operations'; owner = @{ login = 'someone' }; fork = $true; parent = @{ full_name = 'microsoft/github-operations' } }
            } -ParameterFilter { $Endpoint -eq 'repos/someone/github-operations' }
            Mock Invoke-AvmGitHubApi { @{ object = @{ sha = 'sha' } } } -ParameterFilter { $Endpoint -like '*/git/ref/heads/*' }
            Mock Invoke-AvmGitHubApi { @{ html_url = 'https://example.invalid/new' } } -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq 'repos/microsoft/github-operations/pulls'
            }
            Mock Invoke-AvmGitHubApi { throw "Unexpected call: $Method $Endpoint" }
            Request-AvmAppInstallation @Request -Confirm:$false
        }

        $result.Status | Should -Be 'requested'
        $result.PullRequest | Should -Be 'https://example.invalid/new'
    }

    It 'reports the fork failure when no fork of the operations repository can be found' {
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ Request = $script:request; Unlisted = (ConvertTo-TestContentResponse -Repositories @('other')) } {
                param($Request, $Unlisted)
                Mock Invoke-AvmGitHubApi -MockWith ({ $Unlisted }.GetNewClosure()) -ParameterFilter { $Endpoint -like '*/contents/*' }
                Mock Invoke-AvmGitHubApi { @{ items = @() } } -ParameterFilter { $Endpoint -like 'search/issues*' }
                Mock Invoke-AvmGitHubApi { throw [AvmGitHubException]::new('Forking is disabled', 403) } -ParameterFilter { $Endpoint -like '*/forks' }
                Mock Invoke-AvmGitHubApi { @{ login = 'someone' } } -ParameterFilter { $Endpoint -eq 'user' }
                Mock Invoke-AvmGitHubApi { @{ full_name = 'someone/github-operations'; fork = $false } } -ParameterFilter {
                    $Endpoint -eq 'repos/someone/github-operations'
                }
                Mock Invoke-AvmGitHubApi { throw "Unexpected call: $Method $Endpoint" }
                Request-AvmAppInstallation @Request -Confirm:$false
            }
        } | Should -Throw '*Forking is disabled*'
    }
    It 'plans a pull request without writes under WhatIf' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Request = $script:request; Unlisted = (ConvertTo-TestContentResponse -Repositories @('other')) } {
            param($Request, $Unlisted)
            Mock Invoke-AvmGitHubApi -MockWith ({ $Unlisted }.GetNewClosure()) -ParameterFilter { $Endpoint -like '*/contents/*' }
            Mock Invoke-AvmGitHubApi { @{ items = @() } } -ParameterFilter { $Endpoint -like 'search/issues*' }
            Mock Invoke-AvmGitHubApi { throw "Unexpected call: $Method $Endpoint" }
            Request-AvmAppInstallation @Request -WhatIf
        }

        $result.Status | Should -Be 'planned'
        $result.PullRequest | Should -BeNullOrEmpty
    }
}
