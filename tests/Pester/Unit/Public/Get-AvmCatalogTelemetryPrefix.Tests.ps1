#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Published catalog telemetry prefix inventory' {
    It 'collects nested current and historical Bicep and Terraform identifiers' {
        $catalog = @{
            modules = @{
                'Microsoft.Storage/storageAccounts' = @{
                    bicep = @(
                        @{
                            telemetryIdPrefix = '46d3xbcp.res.aaaaaaa'
                            alternativeTelemetryIdPrefixes = @('46d3xbcp.res.bbbbbbb')
                            children = @(
                                @{ telemetryIdPrefix = '46d3xbcp.res.ccccccc' }
                            )
                        }
                    )
                    terraform = @(
                        @{
                            telemetryIdPrefix = '46d3xtrf.res.ddddddd'
                            alternativeTelemetryIdPrefixes = @('46d3xtrf.res.eeeeeee')
                        }
                    )
                }
            }
        }

        $prefixes = @(Get-AvmCatalogTelemetryPrefix -Catalog $catalog -SkipModuleVersionCheck)

        $prefixes | Should -HaveCount 5
        $prefixes | Should -Contain '46d3xbcp.res.aaaaaaa'
        $prefixes | Should -Contain '46d3xbcp.res.bbbbbbb'
        $prefixes | Should -Contain '46d3xbcp.res.ccccccc'
        $prefixes | Should -Contain '46d3xtrf.res.ddddddd'
        $prefixes | Should -Contain '46d3xtrf.res.eeeeeee'
    }

    It 'excludes only the matching Bicep module record when reusing its authored prefix' {
        $catalog = @{
            modules = @{
                storage = @{
                    bicep = @(
                        @{
                            ecosystem = 'bicep'
                            repository = 'Azure/bicep-registry-modules'
                            modulePath = 'avm/res/storage/storage-account'
                            telemetryIdPrefix = '46d3xbcp.res.aaaaaaa'
                            alternativeTelemetryIdPrefixes = @('46d3xbcp.res.bbbbbbb')
                        }
                        @{
                            ecosystem = 'bicep'
                            repository = 'Azure/bicep-registry-modules'
                            modulePath = 'avm/res/storage/another-module'
                            telemetryIdPrefix = '46d3xbcp.res.ccccccc'
                        }
                        @{
                            ecosystem = 'bicep'
                            repository = 'Azure/other-repository'
                            modulePath = 'avm/res/storage/storage-account'
                            telemetryIdPrefix = '46d3xbcp.res.ddddddd'
                        }
                    )
                }
            }
        }

        $prefixes = @(Get-AvmCatalogTelemetryPrefix -Catalog $catalog `
                -ExcludeBicepModulePath 'avm/res/storage/storage-account' -SkipModuleVersionCheck)

        $prefixes | Should -Be @('46d3xbcp.res.ccccccc', '46d3xbcp.res.ddddddd')
    }

    It 'fetches the raw catalog using HTTPS and a bounded timeout' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-WebRequest {
                [pscustomobject]@{
                    Content = '{"modules":{"resource":{"bicep":[{"telemetryIdPrefix":"46d3xbcp.res.123abcd"}]}}}'
                }
            }

            $result = @(Get-AvmCatalogTelemetryPrefix -SkipModuleVersionCheck)

            $result | Should -Be @('46d3xbcp.res.123abcd')
            Should -Invoke Invoke-WebRequest -Exactly 1 -ParameterFilter {
                $Uri -ceq 'https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/main/docs/static/module-indexes/v1/modules.json' -and
                $TimeoutSec -eq 15 -and $UserAgent -like 'Avm.Authoring/*'
            }
        }
    }

    It 'warns on malformed catalog JSON rather than treating the lookup as successful' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = '{"modules":' } }
            $warnings = @()

            $result = @(Get-AvmCatalogTelemetryPrefix -SkipModuleVersionCheck -WarningVariable warnings 3> $null)

            $result | Should -HaveCount 0
            $warnings -join ' ' | Should -Match 'cannot be checked against published identifiers'
        }
    }

    It 'warns and avoids network requests in offline mode' {
        InModuleScope 'Avm.Authoring' {
            $previous = $env:AVM_OFFLINE
            $env:AVM_OFFLINE = '1'
            try {
                Mock Invoke-WebRequest { throw [System.InvalidOperationException]::new('Network must not run.') }
                $warnings = @()

                $result = @(Get-AvmCatalogTelemetryPrefix -SkipModuleVersionCheck -WarningVariable warnings 3> $null)

                $result | Should -HaveCount 0
                $warnings -join ' ' | Should -Match 'AVM_OFFLINE=1'
                Should -Invoke Invoke-WebRequest -Exactly 0
            }
            finally {
                $env:AVM_OFFLINE = $previous
            }
        }
    }

    It 'rejects non-HTTPS catalog URLs with a warning' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-WebRequest { throw [System.InvalidOperationException]::new('HTTP must not run.') }
            $warnings = @()

            $result = @(Get-AvmCatalogTelemetryPrefix -CatalogUri 'http://example.invalid/modules.json' -SkipModuleVersionCheck `
                    -WarningVariable warnings 3> $null)

            $result | Should -HaveCount 0
            $warnings -join ' ' | Should -Match 'must use HTTPS'
            Should -Invoke Invoke-WebRequest -Exactly 0
        }
    }
}
