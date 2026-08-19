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

Describe 'Test-AvmPins' {
    Context 'valid lock' {
        It 'accepts an empty tools list' {
            InModuleScope 'Avm.Authoring' {
                Test-AvmPins -Pins @{ schemaVersion = 1; tools = @() } | Should -BeTrue
            }
        }

        It 'accepts a fully populated entry' {
            $pins = script:NewValidLock
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                Test-AvmPins -Pins $L | Should -BeTrue
            }
        }
    }

    Context 'schema enforcement' {
        It 'rejects a missing schemaVersion' {
            InModuleScope 'Avm.Authoring' {
                { Test-AvmPins -Pins @{ tools = @() } } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects schemaVersion != 1' {
            InModuleScope 'Avm.Authoring' {
                { Test-AvmPins -Pins @{ schemaVersion = 2; tools = @() } } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a missing tools array' {
            InModuleScope 'Avm.Authoring' {
                { Test-AvmPins -Pins @{ schemaVersion = 1 } } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a non-hashtable tool entry' {
            InModuleScope 'Avm.Authoring' {
                $pins = @{ schemaVersion = 1; tools = @('not-a-hashtable') }
                { Test-AvmPins -Pins $pins } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a missing required key' {
            $pins = script:NewValidLock
            $pins.tools[0].Remove('sha256')
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a non-semver version' {
            $pins = script:NewValidLock
            $pins.tools[0].version = '1.9'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an http:// urlTemplate by default' {
            $pins = script:NewValidLock
            $pins.tools[0].urlTemplate = 'http://example.com/{version}'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects file:// urlTemplate by default' {
            $pins = script:NewValidLock
            $pins.tools[0].urlTemplate = 'file:///tmp/payload'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'accepts file:// urlTemplate when -AllowFileUrls is set' {
            $pins = script:NewValidLock
            $pins.tools[0].urlTemplate = 'file:///tmp/payload'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                Test-AvmPins -Pins $L -AllowFileUrls | Should -BeTrue
            }
        }

        It 'rejects an unknown archive value' {
            $pins = script:NewValidLock
            $pins.tools[0].archive = 'rar'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an uppercase entrypoint' {
            $pins = script:NewValidLock
            $pins.tools[0].entrypoint = 'Terraform'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a missing platform in sha256' {
            $pins = script:NewValidLock
            $pins.tools[0].sha256.Remove('darwin-arm64')
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a non-hex sha256 value' {
            $pins = script:NewValidLock
            $pins.tools[0].sha256['linux-amd64'] = 'not-a-hash'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a duplicate tool name' {
            $pins = script:NewValidLock
            $pins.tools = @($pins.tools[0], $pins.tools[0])
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }
    }

    Context 'platformAliases' {
        It 'accepts a tool with platformAliases and a {platform} urlTemplate' {
            $pins = script:NewValidLock
            $pins.tools[0].urlTemplate = 'https://example.com/v{version}/foo-{platform}'
            $pins.tools[0].platformAliases = @{
                'windows-amd64' = 'win-x64.exe'
                'windows-arm64' = 'win-arm64.exe'
                'linux-amd64'   = 'linux-x64'
                'linux-arm64'   = 'linux-arm64'
                'darwin-amd64'  = 'osx-x64'
                'darwin-arm64'  = 'osx-arm64'
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                Test-AvmPins -Pins $L | Should -BeTrue
            }
        }

        It 'rejects {platform} urlTemplate without platformAliases' {
            $pins = script:NewValidLock
            $pins.tools[0].urlTemplate = 'https://example.com/v{version}/foo-{platform}'
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a platformAliases map missing a platform' {
            $pins = script:NewValidLock
            $pins.tools[0].urlTemplate = 'https://example.com/v{version}/foo-{platform}'
            $pins.tools[0].platformAliases = @{
                'windows-amd64' = 'win-x64.exe'
                'windows-arm64' = 'win-arm64.exe'
                'linux-amd64'   = 'linux-x64'
                'linux-arm64'   = 'linux-arm64'
                'darwin-amd64'  = 'osx-x64'
                # darwin-arm64 missing
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an empty platformAliases entry' {
            $pins = script:NewValidLock
            $pins.tools[0].urlTemplate = 'https://example.com/v{version}/foo-{platform}'
            $pins.tools[0].platformAliases = @{
                'windows-amd64' = ''
                'windows-arm64' = 'win-arm64.exe'
                'linux-amd64'   = 'linux-x64'
                'linux-arm64'   = 'linux-arm64'
                'darwin-amd64'  = 'osx-x64'
                'darwin-arm64'  = 'osx-arm64'
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }
    }

    Context 'archives map' {
        It 'accepts a per-platform archives override' {
            $pins = script:NewValidLock
            $pins.tools[0].urlTemplate = 'https://example.com/v{version}/foo-{os}-{arch}{ext}'
            $pins.tools[0].archive = 'tar.gz'
            $pins.tools[0].archives = @{
                'windows-amd64' = 'zip'
                'windows-arm64' = 'zip'
                'linux-amd64'   = 'tar.gz'
                'linux-arm64'   = 'tar.gz'
                'darwin-amd64'  = 'tar.gz'
                'darwin-arm64'  = 'tar.gz'
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                Test-AvmPins -Pins $L | Should -BeTrue
            }
        }

        It 'rejects an archives map missing a supported platform' {
            $pins = script:NewValidLock
            $pins.tools[0].archives = @{
                'windows-amd64' = 'zip'
                'linux-amd64'   = 'tar.gz'
                'linux-arm64'   = 'tar.gz'
                'darwin-amd64'  = 'tar.gz'
                'darwin-arm64'  = 'tar.gz'
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an archives value outside the allowed set' {
            $pins = script:NewValidLock
            $pins.tools[0].archives = @{
                'windows-amd64' = 'rar'
                'windows-arm64' = 'zip'
                'linux-amd64'   = 'tar.gz'
                'linux-arm64'   = 'tar.gz'
                'darwin-amd64'  = 'tar.gz'
                'darwin-arm64'  = 'tar.gz'
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                { Test-AvmPins -Pins $L } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }
    }

    Context 'platformAliases + archives combined' {
        # First exercised in the bundled production lock by 'conftest'
        # (Title-cased OS + x86_64 aliases AND a mixed zip/tar.gz archive
        # map). The validator handles each map with an independent check;
        # this fixture proves the combination stays valid.
        It 'accepts an entry with both platformAliases and archives maps' {
            $pins = script:NewValidLock
            $pins.tools[0].urlTemplate = 'https://example.com/v{version}/foo_{version}_{platform}{ext}'
            $pins.tools[0].archive = 'tar.gz'
            $pins.tools[0].platformAliases = @{
                'windows-amd64' = 'Windows_x86_64'
                'windows-arm64' = 'Windows_arm64'
                'linux-amd64'   = 'Linux_x86_64'
                'linux-arm64'   = 'Linux_arm64'
                'darwin-amd64'  = 'Darwin_x86_64'
                'darwin-arm64'  = 'Darwin_arm64'
            }
            $pins.tools[0].archives = @{
                'windows-amd64' = 'zip'
                'windows-arm64' = 'zip'
                'linux-amd64'   = 'tar.gz'
                'linux-arm64'   = 'tar.gz'
                'darwin-amd64'  = 'tar.gz'
                'darwin-arm64'  = 'tar.gz'
            }
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pins } {
                param($L)
                Test-AvmPins -Pins $L | Should -BeTrue
            }
        }
    }

    Context 'bundled production pin manifest' {
        It 'is valid under the strict (https-only) schema' {
            InModuleScope 'Avm.Authoring' {
                $pins = Read-AvmPins
                Test-AvmPins -Pins $pins | Should -BeTrue
            }
        }

        It 'parses despite JSONC comments and declares every pinned component' {
            $pins = InModuleScope 'Avm.Authoring' { Read-AvmPins }
            $pins.schemaVersion | Should -Be 1
            @($pins.tools).Count | Should -BeGreaterThan 0
            $pins.ContainsKey('policyLibrary') | Should -BeTrue
            $pins.ContainsKey('tflintPlugins') | Should -BeTrue

            $pins.policyLibrary.repository | Should -Be 'Azure/policy-library-avm'
            $pins.policyLibrary.ref        | Should -Match '^v[0-9]'
            $pins.policyLibrary.sha256     | Should -Match '^[0-9a-f]{64}$'
            $pins.policyLibrary.bundles.Keys | Should -Contain 'avm-policy-aprl'
            $pins.policyLibrary.bundles.Keys | Should -Contain 'avm-policy-avmsec'
        }

        It 'mirrors plugin versions and enforces attestation-only AVM configs' {
            $pins = InModuleScope 'Avm.Authoring' { Read-AvmPins }
            $configDir = Join-Path $script:moduleRoot 'Resources' 'tflint'
            $v019Rules = @(
                'deprecated_lock_interface'
                'deprecated_private_endpoints_interface'
                'deprecated_role_assignments_interface'
                'ignore_body_changes'
                'private_endpoints_manage_dns_zone_group'
                'resource_types'
                'retry'
                'timeouts'
            )

            foreach ($config in (Get-ChildItem -LiteralPath $configDir -Filter '*.hcl' -File)) {
                $text = [System.IO.File]::ReadAllText($config.FullName)
                foreach ($plugin in $pins.tflintPlugins.Keys) {
                    $pattern = 'plugin\s+"' + [regex]::Escape($plugin) + '"\s*\{[^}]*?version\s*=\s*"([^"]+)"'
                    $found = [regex]::Match($text, $pattern, 'Singleline')
                    $found.Success | Should -BeTrue -Because "$($config.Name) must declare pinned plugin '$plugin'"
                    $found.Groups[1].Value | Should -Be $pins.tflintPlugins[$plugin] -Because "$($config.Name) must agree with avm.pins.jsonc for plugin '$plugin'"
                }

                $avmPlugin = [regex]::Match($text, 'plugin\s+"avm"\s*\{(?<body>[^}]*)\}', 'Singleline')
                $avmPlugin.Success | Should -BeTrue
                $avmPlugin.Groups['body'].Value | Should -Match 'signature\s*=\s*"attestation"'
                $avmPlugin.Groups['body'].Value | Should -Not -Match 'signing_key\s*='

                $configBlock = [regex]::Match($text, 'config\s*\{(?<body>[^}]*)\}', 'Singleline')
                $configBlock.Success | Should -BeTrue
                $configBlock.Groups['body'].Value | Should -Match 'disabled_by_default\s*=\s*true'

                $expectedState = if ($config.Name -eq 'avm.tflint_example.hcl') { 'false' } else { 'true' }
                foreach ($rule in $v019Rules) {
                    $rulePattern = 'rule\s+"' + [regex]::Escape($rule) + '"\s*\{[^}]*?enabled\s*=\s*' + $expectedState
                    $text | Should -Match $rulePattern -Because "$($config.Name) must explicitly configure v0.19 rule '$rule'"
                }
            }
        }

        It 'keeps managed tool versions out of test stub source' {
            $pins = InModuleScope 'Avm.Authoring' { Read-AvmPins }
            $stubDir = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'fixtures' 'bin')

            $stubs = Get-ChildItem -LiteralPath $stubDir -Filter '*.ps1' -File
            @($stubs).Count | Should -BeGreaterThan 0

            foreach ($stub in $stubs) {
                $pin = $pins.tools | Where-Object { $_.name -eq $stub.BaseName } | Select-Object -First 1
                $pin | Should -Not -BeNullOrEmpty -Because "$($stub.Name) needs a launcher version"

                $source = Get-Content -LiteralPath $stub.FullName -Raw
                $source | Should -Match '\$env:AVM_STUB_TOOL_VERSION'
                $source | Should -Not -Match '(?<!\d)v?\d+\.\d+\.\d+(?!\d)'
            }
        }
    }
}
