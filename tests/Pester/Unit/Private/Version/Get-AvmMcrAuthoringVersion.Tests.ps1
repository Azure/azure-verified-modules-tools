#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Get-AvmMcrAuthoringVersion' {
    BeforeAll {
        $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
        $script:originalMcrSkip = $env:AVM_SKIP_MCR_VERSION_CHECK
        $script:originalOffline = $env:AVM_OFFLINE
        Remove-Item Env:AVM_SKIP_MCR_VERSION_CHECK -ErrorAction SilentlyContinue
        Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
        if ($null -eq $script:originalMcrSkip) {
            Remove-Item Env:AVM_SKIP_MCR_VERSION_CHECK -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_SKIP_MCR_VERSION_CHECK = $script:originalMcrSkip
        }
        if ($null -eq $script:originalOffline) {
            Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_OFFLINE = $script:originalOffline
        }
    }

    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            $script:AvmMcrAuthoringVersion = $null
            $script:AvmMcrAuthoringVersionCheckCompleted = $false
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'Proxy'; Priority = 10; Uri = 'https://proxy.example.test' }
            }
            Mock Wait-AvmRetryDelay {}
        }
    }

    It 'retries a transient transport failure with the advisory retry budget' {
        InModuleScope 'Avm.Authoring' {
            $state = @{ Calls = 0 }
            Mock Invoke-WebRequest {
                $state.Calls++
                if ($state.Calls -eq 1) {
                    throw [System.Net.Http.HttpRequestException]::new('No route to host')
                }
                [pscustomobject]@{
                    StatusCode = 200
                    Headers    = @{}
                    Content    = '{"name":"psresource/avm.authoring","tags":["2.0.0"]}'
                }
            }

            Get-AvmMcrAuthoringVersion | Should -Be ([version]'2.0.0')

            Should -Invoke Invoke-WebRequest -Exactly 2
            Should -Invoke Wait-AvmRetryDelay -Exactly 1
        }
    }

    It 'retries a transient HTTP response with the advisory retry budget' {
        InModuleScope 'Avm.Authoring' {
            $state = @{ Calls = 0 }
            Mock Invoke-WebRequest {
                $state.Calls++
                if ($state.Calls -eq 1) {
                    return [pscustomobject]@{ StatusCode = 503; Headers = @{}; Content = '' }
                }
                [pscustomobject]@{
                    StatusCode = 200
                    Headers    = @{}
                    Content    = '{"name":"psresource/avm.authoring","tags":["2.0.0"]}'
                }
            }

            Get-AvmMcrAuthoringVersion | Should -Be ([version]'2.0.0')

            Should -Invoke Invoke-WebRequest -Exactly 2
            Should -Invoke Wait-AvmRetryDelay -Exactly 1
        }
    }

    It 'does not retry a permanent HTTP response' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-WebRequest {
                [pscustomobject]@{ StatusCode = 404; Headers = @{}; Content = '' }
            }

            { Get-AvmMcrAuthoringVersion } |
                Should -Throw '*MCR Avm.Authoring tag-list request returned HTTP 404*'

            Should -Invoke Invoke-WebRequest -Exactly 1
            Should -Invoke Wait-AvmRetryDelay -Exactly 0
        }
    }
}
