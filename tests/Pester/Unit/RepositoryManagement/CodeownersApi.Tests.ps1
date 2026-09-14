BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:syncRoot = Join-Path $script:root 'repository-management' 'bicep-codeowners-sync'
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:syncRoot 'scripts' 'lib' 'Codeowners.ps1')
    . (Join-Path $script:syncRoot 'scripts' 'lib' 'GitHubSync.ps1')
    $script:template = Get-Content -LiteralPath (Join-Path $script:syncRoot 'CODEOWNERS.template') -Raw
}

Describe 'CODEOWNERS GitHub API boundaries' {
    BeforeEach {
        Mock Invoke-AvmCodeownersGh { throw 'Unmocked CLI invocation; live APIs are forbidden.' }
    }

    It 'uses the existing repository-sync Git blob hashing implementation' {
        Get-AvmCodeownersBlobSha -Bytes ([System.Text.Encoding]::UTF8.GetBytes("hello`n")) |
            Should -BeExactly 'ce013625030ba8dba906f756967f9e9ca394464a'
    }

    It 'rejects empty, null, malformed, and HTML API responses' -ForEach @('', ' ', 'null', '{invalid', '<html>unavailable</html>') {
        $script:response = $_
        Mock Invoke-AvmCodeownersGh { $script:response }
        { Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules' } | Should -Throw
    }

    It 'preserves an explicit empty list without treating it as an API failure' {
        Mock Invoke-AvmCodeownersGh { '[]' }
        @(Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/pulls') | Should -HaveCount 0
    }

    It 'fails visibly on GitHub CLI errors rather than returning an empty list' {
        Mock Invoke-AvmCodeownersGh { throw 'HTTP 403: permission denied' }
        { Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/pulls' } |
            Should -Throw '*permission denied*'
    }

    It 'rejects GraphQL error payloads even when the HTTP request succeeded' {
        Mock Invoke-AvmCodeownersGh { '{"data":null,"errors":[{"message":"Resource not accessible"}]}' }
        { Invoke-AvmCodeownersApi -Endpoint graphql } | Should -Throw '*GraphQL failed*'
    }

    It 'rejects malformed branch references instead of assuming an absent branch' {
        Mock Invoke-AvmCodeownersApi { [pscustomobject]@{ message = 'incomplete response' } }
        { Get-AvmCodeownersBranchSha } | Should -Throw
    }

    It 'does not confuse a similarly named branch with the stable app branch' {
        Mock Invoke-AvmCodeownersApi {
            [pscustomobject]@{
                ref = 'refs/heads/avm-bot/bicep-codeowners-sync-human'
                object = [pscustomobject]@{ type = 'commit'; sha = 'a' * 40 }
            }
        }
        Get-AvmCodeownersBranchSha | Should -BeNullOrEmpty
    }
}

Describe 'CODEOWNERS argv-safe subprocess reuse' {
    It 'selects one executable and forwards literal argv through Invoke-AvmProcess' {
        Mock Get-Command {
            @([pscustomobject]@{ Source = 'first-gh.exe' }, [pscustomobject]@{ Source = 'second-gh.exe' })
        } -ParameterFilter { $Name -eq 'gh' }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            [pscustomobject]@{ StdOut = '{"ok":true}'; ExitCode = 0 }
        }
        $literal = 'literal spaces "quotes" $(not-code); --not-an-option'
        Invoke-AvmCodeownersGh -ArgumentList @('api', '--raw-field', $literal) | Should -BeExactly '{"ok":true}'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Times 1 -Exactly -ParameterFilter {
            $FilePath -ceq 'first-gh.exe' -and $ArgumentList.Count -eq 3 -and
            $ArgumentList[2] -ceq 'literal spaces "quotes" $(not-code); --not-an-option' -and
            $EnvVars.GH_HOST -ceq 'github.com' -and $EnvVars.GH_PROMPT_DISABLED -ceq '1' -and
            $EnvVars.ContainsKey('GITHUB_TOKEN') -and $null -eq $EnvVars.GITHUB_TOKEN -and
            $EnvVars.ContainsKey('GH_DEBUG') -and $null -eq $EnvVars.GH_DEBUG -and $TimeoutSec -eq 120
        }
    }
}

Describe 'Immutable ownership file downloads' {
    BeforeEach {
        $script:bytes = [System.Text.Encoding]::UTF8.GetBytes("hello`n")
        $script:fileResponse = [pscustomobject]@{
            type = 'file'
            path = 'docs/static/module-indexes/BicepResourceModules.csv'
            encoding = 'base64'
            content = [System.Convert]::ToBase64String($script:bytes)
            size = $script:bytes.Length
            sha = Get-AvmCodeownersBlobSha -Bytes $script:bytes
        }
        Mock Invoke-AvmCodeownersApi { $script:fileResponse }
        Mock Invoke-AvmCodeownersGh { throw 'No live API calls are allowed.' }
    }

    It 'verifies exact path, regular file, byte count, blob SHA, and UTF-8' {
        $result = Get-AvmCodeownersGitHubFile -Repository 'Azure/Azure-Verified-Modules' `
            -Path $script:fileResponse.path -Sha ('a' * 40)
        $result.Content | Should -BeExactly "hello`n"
        $result.Sha | Should -BeExactly $script:fileResponse.sha
        Should -Invoke Invoke-AvmCodeownersApi -Times 1 -Exactly -ParameterFilter {
            $Endpoint -ceq ('repos/Azure/Azure-Verified-Modules/contents/docs/static/module-indexes/BicepResourceModules.csv?ref=' + ('a' * 40))
        }
    }

    It 'rejects redirects, symlinks, empty, partial, or corrupted download metadata' -ForEach @(
        @{ Property = 'type'; Value = 'symlink' }
        @{ Property = 'path'; Value = 'unexpected.csv' }
        @{ Property = 'encoding'; Value = 'none' }
        @{ Property = 'size'; Value = 0 }
        @{ Property = 'size'; Value = 99 }
        @{ Property = 'sha'; Value = ('0' * 40) }
        @{ Property = 'content'; Value = 'not base64 !' }
    ) {
        $script:fileResponse.$Property = $Value
        { Get-AvmCodeownersGitHubFile -Repository 'Azure/Azure-Verified-Modules' `
            -Path 'docs/static/module-indexes/BicepResourceModules.csv' -Sha ('a' * 40) } | Should -Throw
    }

    It 'rejects invalid UTF-8 instead of replacing undecodable characters' {
        $bytes = [byte[]]@(0xC3, 0x28)
        $script:fileResponse.content = [System.Convert]::ToBase64String($bytes)
        $script:fileResponse.size = $bytes.Length
        $script:fileResponse.sha = Get-AvmCodeownersBlobSha -Bytes $bytes
        { Get-AvmCodeownersGitHubFile -Repository 'Azure/Azure-Verified-Modules' `
            -Path $script:fileResponse.path -Sha ('a' * 40) } | Should -Throw
    }
}

Describe 'Consistent three-index source snapshots' {
    BeforeEach {
        Mock Invoke-AvmCodeownersApi { [pscustomobject]@{ sha = 'f' * 40 } } `
            -ParameterFilter { $Endpoint -eq 'repos/Azure/Azure-Verified-Modules/commits/main' }
        Mock Invoke-AvmCodeownersGh { throw 'No live API calls are allowed.' }
        Mock Get-AvmCodeownersGitHubFile {
            param($Path)
            $kind = switch -Wildcard ($Path) {
                '*ResourceModules.csv' { 'res' }
                '*PatternModules.csv' { 'ptn' }
                '*UtilityModules.csv' { 'utl' }
                default { throw "Unexpected source path: $Path" }
            }
            [pscustomobject]@{
                Sha = 'e' * 40
                Content = "ModuleName,ModuleStatus,ParentModule,PrimaryModuleOwnerGHHandle,SecondaryModuleOwnerGHHandle`n" +
                    "avm/$kind/test/module,Available,n/a,alice,`n"
            }
        }
    }

    It 'resolves main once and reads all three official files at the same immutable commit' {
        $snapshot = Get-AvmBicepCodeownersSnapshot -Template $script:template
        $snapshot.SourceSha | Should -BeExactly ('f' * 40)
        $snapshot.ModuleCount | Should -Be 3
        $snapshot.IndexShas.Count | Should -Be 3
        Should -Invoke Invoke-AvmCodeownersApi -Times 1 -Exactly
        Should -Invoke Get-AvmCodeownersGitHubFile -Times 3 -Exactly -ParameterFilter {
            $Repository -ceq 'Azure/Azure-Verified-Modules' -and $Sha -ceq ('f' * 40)
        }
    }

    It 'can reproduce a specified source snapshot without reading a mutable source branch' {
        $snapshot = Get-AvmBicepCodeownersSnapshot -Template $script:template -SourceSha ('a' * 40)
        $snapshot.SourceSha | Should -BeExactly ('a' * 40)
        Should -Invoke Invoke-AvmCodeownersApi -Times 0 -Exactly
        Should -Invoke Get-AvmCodeownersGitHubFile -Times 3 -Exactly -ParameterFilter { $Sha -ceq ('a' * 40) }
    }

    It 'fails the whole snapshot if any index cannot be downloaded' {
        Mock Get-AvmCodeownersGitHubFile { throw 'Utility index unavailable' } -ParameterFilter { $Path -like '*UtilityModules.csv' }
        { Get-AvmBicepCodeownersSnapshot -Template $script:template } | Should -Throw '*Utility index unavailable*'
    }
}
