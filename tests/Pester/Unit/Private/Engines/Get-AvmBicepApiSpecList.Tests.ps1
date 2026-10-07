#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..')).ProviderPath
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepApiSpecList' -Tag 'Unit' {
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            $script:apiStatus = 200
            $script:apiBody = '{"Microsoft.Storage":{"storageAccounts":["2023-05-01"]}}'
            $script:apiResponseUri = $null
            Mock Wait-AvmRetryDelay { }
            Mock Write-Warning { }
            Mock Invoke-WebRequest {
                [pscustomobject]@{
                    StatusCode = $script:apiStatus
                    Content = $script:apiBody
                    BaseResponse = [pscustomobject]@{
                        RequestMessage = [pscustomobject]@{
                            RequestUri = if ($null -ne $script:apiResponseUri) {
                                $script:apiResponseUri
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

    It 'reads only the pinned registry API-specification HTTPS endpoint' {
        $specs = InModuleScope 'Avm.Authoring' { Get-AvmBicepApiSpecList }
        $specs['Microsoft.Storage']['storageAccounts'][0] | Should -BeExactly '2023-05-01'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-WebRequest -Exactly 1 -ParameterFilter {
                $Uri.AbsoluteUri -ceq 'https://azure.github.io/Azure-Verified-Modules/governance/apiSpecsList.json' -and
                $MaximumRedirection -eq 0 -and $SkipHttpErrorCheck
            }
        }
    }

    It 'fails for an HTTP or payload that cannot prove API recency: <Case>' -TestCases @(
        @{ Case = 'redirect'; Status = 302; Body = '{}'; Expected = 'HTTP 302' }
        @{ Case = 'unavailable'; Status = 503; Body = '{}'; Expected = 'HTTP 503' }
        @{ Case = 'HTML'; Status = 200; Body = '<html>unavailable</html>'; Expected = 'not valid JSON' }
        @{ Case = 'wrong shape'; Status = 200; Body = '[]'; Expected = 'provider namespace mappings' }
        @{ Case = 'empty providers'; Status = 200; Body = '{}'; Expected = 'provider namespace mappings' }
        @{ Case = 'error envelope'; Status = 200; Body = '{"error":"upstream unavailable"}'; Expected = 'provider namespace mappings' }
        @{ Case = 'malformed provider'; Status = 200; Body = '{"Microsoft.Storage":"upstream unavailable"}'; Expected = 'provider namespace mappings' }
    ) {
        param($Case, $Status, $Body, $Expected)
        InModuleScope 'Avm.Authoring' -Parameters @{
            Code = $Status; Text = $Body; ExpectedText = $Expected
        } {
            param($Code, $Text, $ExpectedText)
            $script:apiStatus = $Code
            $script:apiBody = $Text
            { Get-AvmBicepApiSpecList } | Should -Throw "*$ExpectedText*"
        }
    }

    It 'rejects a response attributable to any other host or path' {
        InModuleScope 'Avm.Authoring' {
            $script:apiResponseUri = [uri]'https://example.com/Azure-Verified-Modules/governance/apiSpecsList.json'
            { Get-AvmBicepApiSpecList } | Should -Throw '*cannot be attributed*'
        }
    }

    It 'does not substitute an empty catalogue after a transport error' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-WebRequest {
                throw [System.Net.Http.HttpRequestException]::new('API source unavailable')
            }
            { Get-AvmBicepApiSpecList } | Should -Throw '*API source unavailable*'
        }
    }

    It 'blocks HTTP outright when AVM_OFFLINE=1' {
        InModuleScope 'Avm.Authoring' {
            $original = $env:AVM_OFFLINE
            try {
                $env:AVM_OFFLINE = '1'
                { Get-AvmBicepApiSpecList } | Should -Throw '*AVM_OFFLINE=1*'
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
