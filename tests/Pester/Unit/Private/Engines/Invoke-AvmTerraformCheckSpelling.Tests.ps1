#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTerraformCheckSpelling' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("tf-spell-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'variables.tf') -Value 'variable "y" {}' -Encoding utf8

        $script:context = [pscustomobject][ordered]@{
            Kind      = 'terraform-module-repo'
            Root      = $script:moduleDir
            Ecosystem = 'terraform'
            Source    = 'path-heuristic'
        }
    }

    It 'rejects a non-terraform context' {
        $bicepCtx = [pscustomobject][ordered]@{
            Kind      = 'bicep-module'
            Root      = $TestDrive
            Ecosystem = 'bicep'
            Source    = 'path-heuristic'
        }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $bicepCtx } {
                param($C)
                Invoke-AvmTerraformCheckSpelling -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'invokes typos with the allowlist and json format, and never with --write-changes' {
        $ctx = $script:context
        $captured = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            $box = @{}
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'typos'; Version = '1.49.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/typos'
                }
            }
            Mock Resolve-AvmTyposConfigPath { '/fake/avm.typos.toml' }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $box.FilePath = $FilePath
                $box.Args = @($ArgumentList)
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformCheckSpelling -Context $C | Out-Null
            $box
        }
        $captured.FilePath | Should -Be '/fake/typos'
        $captured.Args[0]  | Should -Be '--config'
        $captured.Args[1]  | Should -Be '/fake/avm.typos.toml'
        $captured.Args     | Should -Contain '--format'
        $captured.Args     | Should -Contain 'json'
        $captured.Args     | Should -Not -Contain '--write-changes'
        $captured.Args     | Should -Not -Contain '--isolated'
    }

    It 'returns the standard envelope and pass with no findings' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'typos'; Version = '1.49.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/typos'
                }
            }
            Mock Resolve-AvmTyposConfigPath { '/fake/avm.typos.toml' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformCheckSpelling -Context $C
        }
        $result.Engine         | Should -Be 'terraform'
        $result.Tool           | Should -Be 'typos/1.49.0'
        $result.ToolPath       | Should -Be '/fake/typos'
        $result.ToolSource     | Should -Be 'cache'
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 0
        @($result.Issues).Count | Should -Be 0
    }

    It 'maps a finding to a relative path, 1-based column, and AVM-SPELL code' {
        $ctx = $script:context
        $target = Join-Path $script:moduleDir 'variables.tf'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; T = $target } {
            param($C, $T)
            $payload = ([pscustomobject]@{
                    type = 'typo'; path = $T; line_num = 3; byte_offset = 46
                    typo = 'Requries'; corrections = @('Requires')
                } | ConvertTo-Json -Compress)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'typos'; Version = '1.49.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/typos'
                }
            }
            Mock Resolve-AvmTyposConfigPath { '/fake/avm.typos.toml' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 2; StdOut = $payload; StdErr = '' } }
            Invoke-AvmTerraformCheckSpelling -Context $C
        }
        @($result.Issues).Count      | Should -Be 1
        $result.Issues[0].File       | Should -Be 'variables.tf'
        $result.Issues[0].Line       | Should -Be 3
        $result.Issues[0].Column     | Should -Be 47
        $result.Issues[0].Code       | Should -Be 'AVM-SPELL'
        $result.Issues[0].Word       | Should -Be 'Requries'
        $result.Issues[0].Suggestions | Should -Be @('Requires')
        $result.Issues[0].Message    | Should -Be "'Requries' should be 'Requires'"
        $result.FilesProcessed       | Should -Be 1
    }

    It 'anchors a relative typos path to the module root' {
        # typos echoes back the root it was given, so a relative root yields
        # relative paths. Resolving against cwd instead of the module root would
        # break both the generated-README probe and the reported path.
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            $payload = ([pscustomobject]@{
                    type = 'typo'; path = './variables.tf'; line_num = 3; byte_offset = 0
                    typo = 'Requries'; corrections = @('Requires')
                } | ConvertTo-Json -Compress)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'typos'; Version = '1.49.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/typos'
                }
            }
            Mock Resolve-AvmTyposConfigPath { '/fake/avm.typos.toml' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 2; StdOut = $payload; StdErr = '' } }
            Invoke-AvmTerraformCheckSpelling -Context $C
        }
        @($result.Issues).Count | Should -Be 1
        $result.Issues[0].File  | Should -Be 'variables.tf'
    }

    It 'maps AVM1012 to AvmNotSupportedException so the gauntlet skips rather than errors' {
        # typos ships no windows-arm64 binary. Erroring there would make the
        # whole pre-commit chain unusable on a platform where the tool cannot
        # be obtained at all.
        $ctx = $script:context
        $thrown = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool { throw [AvmToolException]::new("Tool 'typos' does not ship a release for 'windows-arm64'.", 'AVM1012') }
            try { $null = Invoke-AvmTerraformCheckSpelling -Context $C; $null }
            catch { $_.Exception }
        }
        $thrown.GetType().Name | Should -Be 'AvmNotSupportedException'
        $thrown.Message | Should -Match 'windows-arm64'
    }

    It 'rethrows a non-AVM1012 tool failure unchanged' {
        $ctx = $script:context
        $thrown = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool { throw [AvmToolException]::new('sha256 mismatch') }
            try { $null = Invoke-AvmTerraformCheckSpelling -Context $C; $null }
            catch { $_.Exception }
        }
        $thrown.GetType().Name | Should -Be 'AvmToolException'
    }

    It 'keeps Status=pass at warning severity but fails at error severity' {
        $ctx = $script:context
        $target = Join-Path $script:moduleDir 'variables.tf'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; T = $target } {
            param($C, $T)
            $payload = ([pscustomobject]@{
                    type = 'typo'; path = $T; line_num = 1; byte_offset = 0
                    typo = 'teh'; corrections = @('the')
                } | ConvertTo-Json -Compress)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'typos'; Version = '1.49.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/typos'
                }
            }
            Mock Resolve-AvmTyposConfigPath { '/fake/avm.typos.toml' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 2; StdOut = $payload; StdErr = '' } }
            [pscustomobject]@{
                Warn = Invoke-AvmTerraformCheckSpelling -Context $C -Severity warning
                Fail = Invoke-AvmTerraformCheckSpelling -Context $C -Severity error
            }
        }
        $result.Warn.Status              | Should -Be 'pass'
        $result.Warn.Issues[0].Severity  | Should -Be 'warning'
        $result.Fail.Status              | Should -Be 'fail'
        $result.Fail.Issues[0].Severity  | Should -Be 'error'
    }

    It 'drops findings in a terraform-docs generated README but keeps source findings' {
        $ctx = $script:context
        $readme = Join-Path $script:moduleDir 'README.md'
        Set-Content -LiteralPath $readme -Value "<!-- BEGIN_TF_DOCS -->`nRequries`n<!-- END_TF_DOCS -->" -Encoding utf8
        $source = Join-Path $script:moduleDir 'variables.tf'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $readme; S = $source } {
            param($C, $R, $S)
            $payload = @(
                ([pscustomobject]@{ type = 'typo'; path = $R; line_num = 2; byte_offset = 0; typo = 'Requries'; corrections = @('Requires') } | ConvertTo-Json -Compress)
                ([pscustomobject]@{ type = 'typo'; path = $S; line_num = 1; byte_offset = 0; typo = 'Requries'; corrections = @('Requires') } | ConvertTo-Json -Compress)
            ) -join "`n"
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'typos'; Version = '1.49.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/typos'
                }
            }
            Mock Resolve-AvmTyposConfigPath { '/fake/avm.typos.toml' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 2; StdOut = $payload; StdErr = '' } }
            Invoke-AvmTerraformCheckSpelling -Context $C
        }
        @($result.Issues).Count | Should -Be 1
        $result.Issues[0].File  | Should -Be 'variables.tf'
    }

    It 'still reports findings in a hand-written README' {
        $ctx = $script:context
        $readme = Join-Path $script:moduleDir 'README.md'
        Set-Content -LiteralPath $readme -Value "# Notes`nRequries a thing." -Encoding utf8
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $readme } {
            param($C, $R)
            $payload = ([pscustomobject]@{ type = 'typo'; path = $R; line_num = 2; byte_offset = 0; typo = 'Requries'; corrections = @('Requires') } | ConvertTo-Json -Compress)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'typos'; Version = '1.49.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/typos'
                }
            }
            Mock Resolve-AvmTyposConfigPath { '/fake/avm.typos.toml' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 2; StdOut = $payload; StdErr = '' } }
            Invoke-AvmTerraformCheckSpelling -Context $C
        }
        @($result.Issues).Count | Should -Be 1
        $result.Issues[0].File  | Should -Be 'README.md'
    }

    It 'throws AvmProcessException when typos exits with an unexpected code' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'typos'; Version = '1.49.0'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/typos'
                    }
                }
                Mock Resolve-AvmTyposConfigPath { '/fake/avm.typos.toml' }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'typos boom' } }
                Invoke-AvmTerraformCheckSpelling -Context $C
            }
        }
        catch { $err = $_.Exception }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'typos boom'
    }
}

Describe 'ConvertFrom-AvmTyposOutput' {
    It 'returns nothing for empty output' {
        $records = InModuleScope 'Avm.Authoring' { , @(ConvertFrom-AvmTyposOutput -Payload '') }
        @($records).Count | Should -Be 0
    }

    It 'parses newline-delimited json rather than a single document' {
        $records = InModuleScope 'Avm.Authoring' {
            $payload = @(
                '{"type":"typo","path":"a.tf","line_num":1,"byte_offset":0,"typo":"teh","corrections":["the"]}'
                '{"type":"typo","path":"b.tf","line_num":2,"byte_offset":4,"typo":"virutal","corrections":["virtual"]}'
            ) -join "`n"
            @(ConvertFrom-AvmTyposOutput -Payload $payload)
        }
        $records.Count      | Should -Be 2
        $records[0].typo    | Should -Be 'teh'
        $records[1].path    | Should -Be 'b.tf'
    }

    It 'ignores records that are not spelling findings' {
        $records = InModuleScope 'Avm.Authoring' {
            $payload = @(
                '{"type":"error","message":"cannot read file"}'
                '{"type":"typo","path":"a.tf","line_num":1,"byte_offset":0,"typo":"teh","corrections":["the"]}'
            ) -join "`n"
            @(ConvertFrom-AvmTyposOutput -Payload $payload)
        }
        $records.Count   | Should -Be 1
        $records[0].typo | Should -Be 'teh'
    }

    It 'throws AvmProcessException on a malformed line' {
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' { ConvertFrom-AvmTyposOutput -Payload 'not json {' }
        }
        catch { $err = $_.Exception }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'typos --format json'
    }
}

Describe 'Test-AvmGeneratedReadme' {
    It 'returns true for a README.md carrying the terraform-docs marker' {
        $path = Join-Path $TestDrive 'gen-README.md'
        $dir = Join-Path $TestDrive ('gen-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'README.md'
        Set-Content -LiteralPath $path -Value "# Title`n<!-- BEGIN_TF_DOCS -->`nbody" -Encoding utf8
        InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P) Test-AvmGeneratedReadme -Path $P
        } | Should -BeTrue
    }

    It 'returns false for a README.md without the marker' {
        $dir = Join-Path $TestDrive ('hand-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'README.md'
        Set-Content -LiteralPath $path -Value "# Hand written" -Encoding utf8
        InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P) Test-AvmGeneratedReadme -Path $P
        } | Should -BeFalse
    }

    It 'returns false for a non-README file that contains the marker' {
        $path = Join-Path $TestDrive ('main-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.tf')
        Set-Content -LiteralPath $path -Value '# BEGIN_TF_DOCS' -Encoding utf8
        InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P) Test-AvmGeneratedReadme -Path $P
        } | Should -BeFalse
    }

    It 'returns false for a missing file' {
        $path = Join-Path $TestDrive 'nowhere/README.md'
        InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P) Test-AvmGeneratedReadme -Path $P
        } | Should -BeFalse
    }
}

Describe 'Resolve-AvmTyposConfigPath' {
    AfterEach {
        Remove-Item Env:\AVM_TYPOS_CONFIG -ErrorAction SilentlyContinue
    }

    It 'resolves the vendored allowlist by default' {
        $resolved = InModuleScope 'Avm.Authoring' { Resolve-AvmTyposConfigPath }
        (Split-Path -Leaf $resolved) | Should -Be 'avm.typos.toml'
        Test-Path -LiteralPath $resolved | Should -BeTrue
    }

    It 'prefers AVM_TYPOS_CONFIG when it points at an existing file' {
        $override = Join-Path $TestDrive ('override-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.toml')
        Set-Content -LiteralPath $override -Value '[default.extend-words]' -Encoding utf8
        $env:AVM_TYPOS_CONFIG = $override
        $resolved = InModuleScope 'Avm.Authoring' { Resolve-AvmTyposConfigPath }
        $resolved | Should -Be (Resolve-Path -LiteralPath $override).ProviderPath
    }

    It 'falls back to the vendored allowlist when the override does not exist' {
        $env:AVM_TYPOS_CONFIG = Join-Path $TestDrive 'does-not-exist.toml'
        $resolved = InModuleScope 'Avm.Authoring' { Resolve-AvmTyposConfigPath }
        (Split-Path -Leaf $resolved) | Should -Be 'avm.typos.toml'
    }
}

Describe 'avm check spelling registration' {
    It 'is routed by the dispatcher to Invoke-AvmCheckSpelling' {
        $entry = InModuleScope 'Avm.Authoring' {
            Get-AvmVerbRegistry | Where-Object { ($_.Path -join ' ') -eq 'check spelling' }
        }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmCheckSpelling'
    }

    It 'is exported from the module manifest' {
        $manifest = Import-PowerShellDataFile (Join-Path $script:moduleRoot 'Avm.Authoring.psd1')
        $manifest.FunctionsToExport | Should -Contain 'Invoke-AvmCheckSpelling'
    }

    It 'ships the vendored allowlist alongside the module' {
        $allowlist = Join-Path $script:moduleRoot 'Resources/typos/avm.typos.toml'
        Test-Path -LiteralPath $allowlist | Should -BeTrue
    }

    It 'pins typos in avm.pins.jsonc' {
        $pins = InModuleScope 'Avm.Authoring' { Read-AvmPins }
        $typos = @($pins.tools | Where-Object { $_.name -eq 'typos' })
        $typos.Count       | Should -Be 1
        $typos[0].entrypoint | Should -Be 'typos'
    }
}
