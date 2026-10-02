#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..')).ProviderPath
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepMcrTagList' -Tag 'Unit' {
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            $script:mcrStatus = 200
            $script:mcrContent = '{"name":"bicep/avm/res/mock/widget","tags":["0.1.0","0.1.2"]}'
            $script:mcrHeaders = @{}
            $script:mcrResponseUri = $null
            Mock Invoke-WebRequest {
                [pscustomobject]@{
                    StatusCode = $script:mcrStatus
                    Content = $script:mcrContent
                    Headers = $script:mcrHeaders
                    BaseResponse = [pscustomobject]@{
                        RequestMessage = [pscustomobject]@{
                            RequestUri = if ($null -ne $script:mcrResponseUri) {
                                $script:mcrResponseUri
                            }
                            else {
                                $Uri
                            }
                        }
                    }
                }
            }
        }
    }

    It 'reads the complete version list from the exact HTTPS module endpoint without redirects' {
        $result = InModuleScope 'Avm.Authoring' {
            Get-AvmBicepMcrTagList -ModulePath 'avm/res/mock/widget'
        }
        $result.Exists | Should -BeTrue
        @($result.Tags).Count | Should -Be 2
        $result.Tags.Contains('0.1.0') | Should -BeTrue
        $result.Tags.Contains('0.1.2') | Should -BeTrue
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-WebRequest -Exactly 1 -ParameterFilter {
                $Uri.AbsoluteUri -ceq 'https://mcr.microsoft.com/v2/bicep/avm/res/mock/widget/tags/list' -and
                $MaximumRedirection -eq 0 -and $SkipHttpErrorCheck
            }
        }
    }

    It 'only treats a matching NAME_UNKNOWN registry response as unpublished' {
        InModuleScope 'Avm.Authoring' {
            $script:mcrStatus = 404
            $script:mcrContent = '{"errors":[{"code":"NAME_UNKNOWN","detail":{"name":"bicep/avm/res/mock/widget"}}]}'
        }
        $result = InModuleScope 'Avm.Authoring' {
            Get-AvmBicepMcrTagList -ModulePath 'avm/res/mock/widget'
        }
        $result.Exists | Should -BeFalse
        $result.Tags.Count | Should -Be 0
    }

    It 'follows same-endpoint pagination rather than silently accepting a partial tag list' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-WebRequest {
                $first = -not $Uri.Query
                [pscustomobject]@{
                    StatusCode = 200
                    Content = if ($first) {
                        '{"name":"bicep/avm/res/mock/widget","tags":["0.1.0"]}'
                    }
                    else {
                        '{"name":"bicep/avm/res/mock/widget","tags":["0.1.1"]}'
                    }
                    Headers = if ($first) {
                        @{ Link = '</v2/bicep/avm/res/mock/widget/tags/list?n=100&last=0.1.0>; rel="next"' }
                    }
                    else {
                        @{}
                    }
                    BaseResponse = [pscustomobject]@{
                        RequestMessage = [pscustomobject]@{ RequestUri = $Uri }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' {
            Get-AvmBicepMcrTagList -ModulePath 'avm/res/mock/widget'
        }
        @($result.Tags).Count | Should -Be 2
        $result.Tags.Contains('0.1.1') | Should -BeTrue
        InModuleScope 'Avm.Authoring' { Should -Invoke Invoke-WebRequest -Exactly 2 }
    }

    It 'fails on invalid status, shape, versions, not-found bodies and pagination: <Case>' -TestCases @(
        @{ Case = 'redirect'; Status = 302; Body = '{}'; Link = $null; Expected = 'HTTP 302' }
        @{ Case = 'service unavailable'; Status = 503; Body = '{}'; Link = $null; Expected = 'HTTP 503' }
        @{ Case = 'HTML not found'; Status = 404; Body = '<html>Missing</html>'; Link = $null; Expected = 'not valid JSON' }
        @{ Case = 'wrong error'; Status = 404; Body = '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}'; Link = $null; Expected = 'NAME_UNKNOWN' }
        @{ Case = 'wrong not-found name'; Status = 404; Body = '{"errors":[{"code":"NAME_UNKNOWN","detail":{"name":"bicep/avm/res/mock/other"}}]}'; Link = $null; Expected = 'different repository' }
        @{ Case = 'wrong module name'; Status = 200; Body = '{"name":"bicep/avm/res/mock/other","tags":[]}'; Link = $null; Expected = 'expected repository name' }
        @{ Case = 'missing tag list'; Status = 200; Body = '{"name":"bicep/avm/res/mock/widget","tags":null}'; Link = $null; Expected = 'tags array' }
        @{ Case = 'non-version tag'; Status = 200; Body = '{"name":"bicep/avm/res/mock/widget","tags":["latest"]}'; Link = $null; Expected = 'invalid or duplicate' }
        @{ Case = 'duplicate version'; Status = 200; Body = '{"name":"bicep/avm/res/mock/widget","tags":["0.1.0","0.1.0"]}'; Link = $null; Expected = 'invalid or duplicate' }
        @{ Case = 'wrong host link'; Status = 200; Body = '{"name":"bicep/avm/res/mock/widget","tags":[]}'; Link = '<https://example.com/v2/bicep/avm/res/mock/widget/tags/list?last=0.1.0>; rel="next"'; Expected = 'unapproved HTTPS' }
        @{ Case = 'wrong path link'; Status = 200; Body = '{"name":"bicep/avm/res/mock/widget","tags":[]}'; Link = '</v2/bicep/avm/res/mock/other/tags/list?last=0.1.0>; rel="next"'; Expected = 'unapproved HTTPS' }
        @{ Case = 'unknown link syntax'; Status = 200; Body = '{"name":"bicep/avm/res/mock/widget","tags":[]}'; Link = '</v2/bicep/avm/res/mock/widget/tags/list>; rel="prev"'; Expected = 'uninspectable pagination' }
    ) {
        param($Case, $Status, $Body, $Link, $Expected)
        InModuleScope 'Avm.Authoring' -Parameters @{
            Code = $Status; Text = $Body; PageLink = $Link; ErrorText = $Expected
        } {
            param($Code, $Text, $PageLink, $ErrorText)
            $script:mcrStatus = $Code
            $script:mcrContent = $Text
            if ($null -ne $PageLink) { $script:mcrHeaders = @{ Link = $PageLink } }
            { Get-AvmBicepMcrTagList -ModulePath 'avm/res/mock/widget' } |
                Should -Throw "*$ErrorText*"
        }
    }

    It 'fails if the response cannot be attributed to the request' {
        InModuleScope 'Avm.Authoring' {
            $script:mcrResponseUri = [uri]'https://example.com/v2/bicep/avm/res/mock/widget/tags/list'
            { Get-AvmBicepMcrTagList -ModulePath 'avm/res/mock/widget' } |
                Should -Throw '*cannot be attributed*'
        }
    }

    It 'reports transport failures instead of treating the module as unpublished' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('MCR unavailable') }
            { Get-AvmBicepMcrTagList -ModulePath 'avm/res/mock/widget' } |
                Should -Throw '*MCR unavailable*'
        }
    }

    It 'does not send HTTP in offline mode or for an invalid module path' {
        InModuleScope 'Avm.Authoring' {
            $original = $env:AVM_OFFLINE
            try {
                $env:AVM_OFFLINE = '1'
                { Get-AvmBicepMcrTagList -ModulePath 'avm/res/mock/widget' } |
                    Should -Throw '*AVM_OFFLINE=1*'
                { Get-AvmBicepMcrTagList -ModulePath 'avm/res/mock/widget/../other' } |
                    Should -Throw '*Invalid Bicep module path*'
                Should -Invoke Invoke-WebRequest -Exactly 0
            }
            finally {
                if ($null -eq $original) {
                    Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
                }
                else {
                    $env:AVM_OFFLINE = $original
                }
            }
        }
    }
}
