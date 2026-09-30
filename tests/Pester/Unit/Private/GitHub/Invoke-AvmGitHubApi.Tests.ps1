#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmGitHubApi' {
    It 'calls gh api for github.com without prompts and parses a JSON object' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmApplicationPath { '/fake/gh' }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = '{"name":"repo","permissions":{"admin":true}}'; StdErr = '' }
            }

            $result = Invoke-AvmGitHubApi -Endpoint 'repos/Azure/repo'

            $result['name'] | Should -BeExactly 'repo'
            $result['permissions']['admin'] | Should -BeTrue
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/gh' -and
                ($ArgumentList -join ' ') -like 'api --hostname github.com --method GET *' -and
                $ArgumentList -contains 'Accept: application/vnd.github+json' -and
                $ArgumentList[-1] -eq 'repos/Azure/repo' -and
                $ArgumentList -notcontains '--input' -and
                $IgnoreExitCode -and
                $EnvVars.GH_HOST -eq 'github.com' -and
                $EnvVars.GH_PROMPT_DISABLED -eq '1' -and
                $EnvVars.ContainsKey('GH_DEBUG') -and $null -eq $EnvVars.GH_DEBUG
            }
        }
    }

    It 'requests the given media type' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmApplicationPath { '/fake/gh' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' } }
            $null = Invoke-AvmGitHubApi -Endpoint 'orgs/Azure/teams/t/repos/Azure/repo' -Accept 'application/vnd.github.v3.repository+json'
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList -contains 'Accept: application/vnd.github.v3.repository+json' -and
                $ArgumentList -notcontains 'Accept: application/vnd.github+json'
            }
        }
    }

    It 'writes list responses to the pipeline one item at a time' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmApplicationPath { '/fake/gh' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = '[{"slug":"a"},{"slug":"b"}]'; StdErr = '' } }
            $items = @(Invoke-AvmGitHubApi -Endpoint 'repos/Azure/repo/teams')
            $items.Count | Should -Be 2
            $items[1]['slug'] | Should -BeExactly 'b'

            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' } }
            @(Invoke-AvmGitHubApi -Endpoint 'repos/Azure/repo/teams').Count | Should -Be 0

            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmGitHubApi -Endpoint 'repos/Azure/repo' -Method PUT | Should -BeNullOrEmpty
        }
    }

    It 'sends the body as a JSON file and deletes the file afterwards' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmApplicationPath { '/fake/gh' }
            Mock Invoke-AvmProcess {
                $script:capturedBodyPath = $ArgumentList[[array]::IndexOf($ArgumentList, '--input') + 1]
                $script:capturedBody = [System.IO.File]::ReadAllText($script:capturedBodyPath)
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            $body = @{ properties = @(@{ property_name = 'global-rulesets-opt-out'; value = $null }) }
            $null = Invoke-AvmGitHubApi -Endpoint 'repos/Azure/repo/properties/values' -Method PATCH -Body $body

            $script:capturedBody | Should -Match '"value":null'
            ($script:capturedBody | ConvertFrom-Json).properties[0].property_name | Should -BeExactly 'global-rulesets-opt-out'
            [System.IO.File]::Exists($script:capturedBodyPath) | Should -BeFalse
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { ($ArgumentList -join ' ') -like '*--method PATCH*' }
        }
    }

    It 'returns $null for 404 only when not-found is allowed' {
        $probe = InModuleScope 'Avm.Authoring' {
            Mock Get-AvmApplicationPath { '/fake/gh' }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 1; StdOut = '{"message":"Not Found","status":"404"}'; StdErr = 'gh: Not Found (HTTP 404)' }
            }
            Invoke-AvmGitHubApi -Endpoint 'repos/Azure/missing' -AllowNotFound | Should -BeNullOrEmpty
            try { Invoke-AvmGitHubApi -Endpoint 'repos/Azure/missing' } catch { $_.Exception }
        }

        $probe.GetType().Name | Should -Be 'AvmGitHubException'
        $probe.StatusCode | Should -Be 404
        $probe.Message | Should -Match 'GET repos/Azure/missing failed with HTTP 404: Not Found'
    }

    It 'includes validation error details in the failure' {
        $probe = InModuleScope 'Avm.Authoring' {
            Mock Get-AvmApplicationPath { '/fake/gh' }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 1
                    StdOut   = '{"message":"Repository creation failed.","errors":[{"field":"name","message":"name already exists on this account"}]}'
                    StdErr   = 'gh: Repository creation failed. (HTTP 422)'
                }
            }
            try { Invoke-AvmGitHubApi -Endpoint 'orgs/Azure/repos' -Method POST -Body @{ name = 'x' } } catch { $_.Exception }
        }

        $probe.StatusCode | Should -Be 422
        $probe.Message | Should -Match 'Repository creation failed\. name already exists on this account'
    }

    It 'falls back to standard error when gh fails before an HTTP response' {
        $probe = InModuleScope 'Avm.Authoring' {
            Mock Get-AvmApplicationPath { '/fake/gh' }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 4; StdOut = ''; StdErr = 'To get started with GitHub CLI, please run:  gh auth login' }
            }
            try { Invoke-AvmGitHubApi -Endpoint 'user' } catch { $_.Exception }
        }

        $probe.StatusCode | Should -Be 0
        $probe.Message | Should -Match 'GET user failed: To get started with GitHub CLI'
    }
}
