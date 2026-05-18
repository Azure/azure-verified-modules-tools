#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    function script:NewValidLock {
        @{
            schemaVersion = 1
            tools         = @(
                @{
                    name        = 'terraform'
                    version     = '1.9.5'
                    urlTemplate = 'https://releases.hashicorp.com/terraform/{version}/terraform_{version}_{os}_{arch}.zip'
                    archive     = 'zip'
                    entrypoint  = 'terraform'
                    sha256      = @{
                        'windows-amd64' = ('a' * 64)
                        'windows-arm64' = ('b' * 64)
                        'linux-amd64'   = ('c' * 64)
                        'linux-arm64'   = ('d' * 64)
                        'darwin-amd64'  = ('e' * 64)
                        'darwin-arm64'  = ('f' * 64)
                    }
                }
            )
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Test-AvmToolsLock' {
    Context 'valid lock' {
        It 'accepts an empty tools list' {
            InModuleScope 'Avm.Authoring' {
                Test-AvmToolsLock -Lock @{ schemaVersion = 1; tools = @() } | Should -BeTrue
            }
        }

        It 'accepts a fully populated entry' {
            $lock = script:NewValidLock
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                Test-AvmToolsLock -Lock $L | Should -BeTrue
            }
        }
    }

    Context 'schema enforcement' {
        It 'rejects a missing schemaVersion' {
            InModuleScope 'Avm.Authoring' {
                { Test-AvmToolsLock -Lock @{ tools = @() } } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects schemaVersion != 1' {
            InModuleScope 'Avm.Authoring' {
                { Test-AvmToolsLock -Lock @{ schemaVersion = 2; tools = @() } } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a missing tools array' {
            InModuleScope 'Avm.Authoring' {
                { Test-AvmToolsLock -Lock @{ schemaVersion = 1 } } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a non-hashtable tool entry' {
            InModuleScope 'Avm.Authoring' {
                $lock = @{ schemaVersion = 1; tools = @('not-a-hashtable') }
                { Test-AvmToolsLock -Lock $lock } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a missing required key' {
            $lock = script:NewValidLock
            $lock.tools[0].Remove('sha256')
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a non-semver version' {
            $lock = script:NewValidLock
            $lock.tools[0].version = '1.9'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an http:// urlTemplate by default' {
            $lock = script:NewValidLock
            $lock.tools[0].urlTemplate = 'http://example.com/{version}'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects file:// urlTemplate by default' {
            $lock = script:NewValidLock
            $lock.tools[0].urlTemplate = 'file:///tmp/payload'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'accepts file:// urlTemplate when -AllowFileUrls is set' {
            $lock = script:NewValidLock
            $lock.tools[0].urlTemplate = 'file:///tmp/payload'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                Test-AvmToolsLock -Lock $L -AllowFileUrls | Should -BeTrue
            }
        }

        It 'rejects an unknown archive value' {
            $lock = script:NewValidLock
            $lock.tools[0].archive = 'rar'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an uppercase entrypoint' {
            $lock = script:NewValidLock
            $lock.tools[0].entrypoint = 'Terraform'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a missing platform in sha256' {
            $lock = script:NewValidLock
            $lock.tools[0].sha256.Remove('darwin-arm64')
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a non-hex sha256 value' {
            $lock = script:NewValidLock
            $lock.tools[0].sha256['linux-amd64'] = 'not-a-hash'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a duplicate tool name' {
            $lock = script:NewValidLock
            $lock.tools = @($lock.tools[0], $lock.tools[0])
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }
    }

    Context 'platformAliases' {
        It 'accepts a tool with platformAliases and a {platform} urlTemplate' {
            $lock = script:NewValidLock
            $lock.tools[0].urlTemplate = 'https://example.com/v{version}/foo-{platform}'
            $lock.tools[0].platformAliases = @{
                'windows-amd64' = 'win-x64.exe'
                'windows-arm64' = 'win-arm64.exe'
                'linux-amd64'   = 'linux-x64'
                'linux-arm64'   = 'linux-arm64'
                'darwin-amd64'  = 'osx-x64'
                'darwin-arm64'  = 'osx-arm64'
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                Test-AvmToolsLock -Lock $L | Should -BeTrue
            }
        }

        It 'rejects {platform} urlTemplate without platformAliases' {
            $lock = script:NewValidLock
            $lock.tools[0].urlTemplate = 'https://example.com/v{version}/foo-{platform}'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a platformAliases map missing a platform' {
            $lock = script:NewValidLock
            $lock.tools[0].urlTemplate = 'https://example.com/v{version}/foo-{platform}'
            $lock.tools[0].platformAliases = @{
                'windows-amd64' = 'win-x64.exe'
                'windows-arm64' = 'win-arm64.exe'
                'linux-amd64'   = 'linux-x64'
                'linux-arm64'   = 'linux-arm64'
                'darwin-amd64'  = 'osx-x64'
                # darwin-arm64 missing
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an empty platformAliases entry' {
            $lock = script:NewValidLock
            $lock.tools[0].urlTemplate = 'https://example.com/v{version}/foo-{platform}'
            $lock.tools[0].platformAliases = @{
                'windows-amd64' = ''
                'windows-arm64' = 'win-arm64.exe'
                'linux-amd64'   = 'linux-x64'
                'linux-arm64'   = 'linux-arm64'
                'darwin-amd64'  = 'osx-x64'
                'darwin-arm64'  = 'osx-arm64'
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }
    }

    Context 'archives map' {
        It 'accepts a per-platform archives override' {
            $lock = script:NewValidLock
            $lock.tools[0].urlTemplate = 'https://example.com/v{version}/foo-{os}-{arch}{ext}'
            $lock.tools[0].archive = 'tar.gz'
            $lock.tools[0].archives = @{
                'windows-amd64' = 'zip'
                'windows-arm64' = 'zip'
                'linux-amd64'   = 'tar.gz'
                'linux-arm64'   = 'tar.gz'
                'darwin-amd64'  = 'tar.gz'
                'darwin-arm64'  = 'tar.gz'
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                Test-AvmToolsLock -Lock $L | Should -BeTrue
            }
        }

        It 'rejects an archives map missing a supported platform' {
            $lock = script:NewValidLock
            $lock.tools[0].archives = @{
                'windows-amd64' = 'zip'
                'linux-amd64'   = 'tar.gz'
                'linux-arm64'   = 'tar.gz'
                'darwin-amd64'  = 'tar.gz'
                'darwin-arm64'  = 'tar.gz'
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an archives value outside the allowed set' {
            $lock = script:NewValidLock
            $lock.tools[0].archives = @{
                'windows-amd64' = 'rar'
                'windows-arm64' = 'zip'
                'linux-amd64'   = 'tar.gz'
                'linux-arm64'   = 'tar.gz'
                'darwin-amd64'  = 'tar.gz'
                'darwin-arm64'  = 'tar.gz'
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lock } {
                param($L)
                { Test-AvmToolsLock -Lock $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }
    }

    Context 'bundled production lock' {
        It 'is valid under the strict (https-only) schema' {
            $lockPath = Resolve-Path (Join-Path $script:moduleRoot 'Resources' 'tools.lock.psd1')
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $lockPath.Path } {
                param($P)
                $lock = Import-PowerShellDataFile -LiteralPath $P
                Test-AvmToolsLock -Lock $lock | Should -BeTrue
            }
        }
    }
}
