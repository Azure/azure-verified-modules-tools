#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    $script:savedRunnerDebug = $env:RUNNER_DEBUG
    $script:savedAvmVerbose = $env:AVM_VERBOSE
}

AfterAll {
    $env:RUNNER_DEBUG = $script:savedRunnerDebug
    $env:AVM_VERBOSE = $script:savedAvmVerbose
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-AvmTflintConfigDir' {
    AfterEach {
        Remove-Item Env:\AVM_TFLINT_CONFIG_DIR -ErrorAction SilentlyContinue
    }

    It 'resolves the vendored Resources/tflint directory by default' {
        $dir = InModuleScope 'Avm.Authoring' { Resolve-AvmTflintConfigDir }
        $dir | Should -Not -BeNullOrEmpty
        (Join-Path $dir 'avm.tflint.hcl')         | Should -Exist
        (Join-Path $dir 'avm.tflint_module.hcl')  | Should -Exist
        (Join-Path $dir 'avm.tflint_example.hcl') | Should -Exist
    }

    It 'honours AVM_TFLINT_CONFIG_DIR when it holds all three configs' {
        $override = Join-Path $TestDrive 'override-cfg'
        New-Item -ItemType Directory -Path $override -Force | Out-Null
        foreach ($f in @('avm.tflint.hcl', 'avm.tflint_module.hcl', 'avm.tflint_example.hcl')) {
            Set-Content -LiteralPath (Join-Path $override $f) -Value 'config {}' -Encoding utf8
        }
        $env:AVM_TFLINT_CONFIG_DIR = $override

        $dir = InModuleScope 'Avm.Authoring' { Resolve-AvmTflintConfigDir }
        (Resolve-Path -LiteralPath $dir).ProviderPath | Should -Be (Resolve-Path -LiteralPath $override).ProviderPath
    }

    It 'ignores an incomplete AVM_TFLINT_CONFIG_DIR and falls back to Resources' {
        $override = Join-Path $TestDrive 'incomplete-cfg'
        New-Item -ItemType Directory -Path $override -Force | Out-Null
        # Only two of the three required configs.
        Set-Content -LiteralPath (Join-Path $override 'avm.tflint.hcl') -Value 'config {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $override 'avm.tflint_module.hcl') -Value 'config {}' -Encoding utf8
        $env:AVM_TFLINT_CONFIG_DIR = $override

        $dir = InModuleScope 'Avm.Authoring' { Resolve-AvmTflintConfigDir }
        (Resolve-Path -LiteralPath $dir).ProviderPath | Should -Not -Be (Resolve-Path -LiteralPath $override).ProviderPath
        (Join-Path $dir 'avm.tflint_example.hcl') | Should -Exist
    }
}

Describe 'Merge-AvmTflintConfig' {
    BeforeEach {
        $script:basePath = Join-Path $TestDrive 'base.hcl'
        $script:overridePath = Join-Path $TestDrive 'override.hcl'
        $script:destinationPath = Join-Path $TestDrive 'merged.hcl'
    }

    It 'applies a genuine rule-disable override without dropping base attributes' {
        @'
plugin "avm" {
  enabled = true
  version = "0.16.0"
  source  = "github.com/Azure/tflint-ruleset-avm"
}

rule "managed_identities" {
  enabled = true
}
'@ | Set-Content -LiteralPath $script:basePath -Encoding utf8
        @'
# Used by terraform-azurerm-avm-res-containerservice-managedcluster.
rule "managed_identities" {
  enabled = false
}
'@ | Set-Content -LiteralPath $script:overridePath -Encoding utf8

        InModuleScope 'Avm.Authoring' -Parameters @{
            B = $script:basePath; O = $script:overridePath; D = $script:destinationPath
        } {
            param($B, $O, $D)
            Merge-AvmTflintConfig -BasePath $B -OverridePath $O -DestinationPath $D
        }

        $merged = Get-Content -LiteralPath $script:destinationPath -Raw
        $merged | Should -Match '(?s)rule "managed_identities"\s*\{\s*enabled = false\s*\}'
        $merged | Should -Match 'version = "0.16.0"'
        $merged | Should -Match 'source\s+= "github.com/Azure/tflint-ruleset-avm"'
    }

    It 'merges attributes into the last duplicate block like pinned hclmerge' {
        @'
rule "diagnostic_settings" {
  enabled = true
}

rule "diagnostic_settings" {
  enabled = true
}
'@ | Set-Content -LiteralPath $script:basePath -Encoding utf8
        @'
rule "diagnostic_settings" {
  enabled = false
}
'@ | Set-Content -LiteralPath $script:overridePath -Encoding utf8

        InModuleScope 'Avm.Authoring' -Parameters @{
            B = $script:basePath; O = $script:overridePath; D = $script:destinationPath
        } {
            param($B, $O, $D)
            Merge-AvmTflintConfig -BasePath $B -OverridePath $O -DestinationPath $D
        }

        $merged = Get-Content -LiteralPath $script:destinationPath -Raw
        $blocks = [regex]::Matches($merged, '(?s)rule "diagnostic_settings"\s*\{(?<body>[^{}]*)\}')
        $blocks.Count | Should -Be 2
        $blocks[0].Groups['body'].Value | Should -Match 'enabled = true'
        $blocks[1].Groups['body'].Value | Should -Match 'enabled = false'
    }

    It 'retains unspecified plugin attributes and appends new blocks' {
        @'
plugin "avm" {
  enabled = true
  version = "0.16.0"
  source  = "github.com/Azure/tflint-ruleset-avm"
}
'@ | Set-Content -LiteralPath $script:basePath -Encoding utf8
        @'
plugin "avm" {
  enabled = false
}

rule "custom_rule" {
  enabled = false
}
'@ | Set-Content -LiteralPath $script:overridePath -Encoding utf8

        InModuleScope 'Avm.Authoring' -Parameters @{
            B = $script:basePath; O = $script:overridePath; D = $script:destinationPath
        } {
            param($B, $O, $D)
            Merge-AvmTflintConfig -BasePath $B -OverridePath $O -DestinationPath $D
        }

        $merged = Get-Content -LiteralPath $script:destinationPath -Raw
        $merged | Should -Match '(?s)plugin "avm"\s*\{[^{}]*enabled = false'
        $merged | Should -Match 'version = "0.16.0"'
        $merged | Should -Match '(?s)rule "custom_rule"\s*\{\s*enabled = false\s*\}'
    }

    It 'rejects unsupported nested override blocks instead of silently changing semantics' {
        'rule "x" { enabled = true }' | Set-Content -LiteralPath $script:basePath -Encoding utf8
        @'
rule "x" {
  enabled = false
  option {
    value = true
  }
}
'@ | Set-Content -LiteralPath $script:overridePath -Encoding utf8

        {
            InModuleScope 'Avm.Authoring' -Parameters @{
                B = $script:basePath; O = $script:overridePath; D = $script:destinationPath
            } {
                param($B, $O, $D)
                Merge-AvmTflintConfig -BasePath $B -OverridePath $O -DestinationPath $D
            }
        } | Should -Throw '*unsupported HCL*'
    }
}

Describe 'Get-AvmTflintScope' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ("scope-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:cfg = Join-Path $TestDrive 'cfgdir'
    }

    It 'returns only the root scope when modules/ and examples/ are absent' {
        $scopes = @(InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:root; C = $script:cfg } {
            param($R, $C)
            Get-AvmTflintScope -Root $R -ConfigDir $C
        })
        $scopes.Count | Should -Be 1
        $scopes[0].Label  | Should -Be 'root'
        $scopes[0].RelPath | Should -Be '.'
        $scopes[0].Config  | Should -BeLike '*avm.tflint.hcl'
    }

    It 'orders scopes root -> modules (sorted) -> examples (sorted) with matching configs' {
        # Create out of alphabetical order to prove sorting.
        foreach ($m in @('foo', 'bar')) {
            New-Item -ItemType Directory -Path (Join-Path $script:root (Join-Path 'modules' $m)) -Force | Out-Null
        }
        foreach ($e in @('default', 'alt')) {
            New-Item -ItemType Directory -Path (Join-Path $script:root (Join-Path 'examples' $e)) -Force | Out-Null
        }

        $scopes = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:root; C = $script:cfg } {
            param($R, $C)
            Get-AvmTflintScope -Root $R -ConfigDir $C
        }

        @($scopes).Count | Should -Be 5
        $scopes[0].Label | Should -Be 'root'
        $scopes[1].Label | Should -Be 'modules/bar'
        $scopes[2].Label | Should -Be 'modules/foo'
        $scopes[3].Label | Should -Be 'examples/alt'
        $scopes[4].Label | Should -Be 'examples/default'

        $scopes[1].Config | Should -BeLike '*avm.tflint_module.hcl'
        $scopes[2].Config | Should -BeLike '*avm.tflint_module.hcl'
        $scopes[3].Config | Should -BeLike '*avm.tflint_example.hcl'
        $scopes[4].Config | Should -BeLike '*avm.tflint_example.hcl'
    }
}

Describe 'Invoke-AvmTerraformLint' {
    BeforeEach {
        $env:RUNNER_DEBUG = ''
        $env:AVM_VERBOSE = ''
        $script:moduleDir = Join-Path $TestDrive ("tf-mod-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Value 'variable "x" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'variables.tf') -Value 'variable "y" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'README.md') -Value '# readme' -Encoding utf8

        $script:context = [pscustomobject][ordered]@{
            Kind      = 'terraform-module-repo'
            Root      = $script:moduleDir
            Ecosystem = 'terraform'
            Source    = 'path-heuristic'
        }

        $script:lintCache = Join-Path $TestDrive ("lint-cache-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        InModuleScope 'Avm.Authoring' -Parameters @{ Cache = $script:lintCache } {
            param($Cache)
            $script:lintTestCache = $Cache
            Mock Get-AvmFolder { $script:lintTestCache } -ParameterFilter { $Kind -eq 'Cache' }
            Mock Invoke-AvmProcess -ParameterFilter {
                $ArgumentList.Count -gt 0 -and $ArgumentList[0] -eq 'init'
            } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
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
                Invoke-AvmTerraformLint -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'initializes Terraform in an isolated copy before TFLint runs the root ruleset' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'tflint'; Version = '0.55.1'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/tflint'
                }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            $r = Invoke-AvmTerraformLint -Context $C

            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList.Count -eq 2 -and
                $ArgumentList[0] -eq 'init' -and
                $ArgumentList[1] -eq '-input=false' -and
                $WorkingDirectory -ne $C.Root -and
                -not [bool]$StreamOutput
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/tflint' -and
                ($ArgumentList -contains '--init') -and
                (($ArgumentList -join '|') -like '*avm.tflint.hcl*') -and
                -not [bool]$StreamOutput
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/tflint' -and
                ($ArgumentList -contains '--format=json') -and
                ($ArgumentList -contains '--minimum-failure-severity=warning') -and
                (($ArgumentList -join '|') -like '*avm.tflint.hcl*') -and
                -not [bool]$StreamOutput
            }
            $r
        }
        $result.Engine         | Should -Be 'terraform'
        $result.Tool           | Should -Be 'tflint/0.55.1'
        $result.ToolPath       | Should -Be '/fake/tflint'
        $result.ToolSource     | Should -Be 'cache'
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 2
    }

    It 'streams subprocess output when <Mode> enables verbose logging' -TestCases @(
        @{ Mode = '-Verbose'; RunnerDebug = ''; UseVerbose = $true }
        @{ Mode = 'GitHub Actions debug mode'; RunnerDebug = '1'; UseVerbose = $false }
    ) {
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{
            C = $ctx; DebugValue = $RunnerDebug; EnableVerbose = $UseVerbose
        } {
            param($C, $DebugValue, $EnableVerbose)
            $env:RUNNER_DEBUG = $DebugValue
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            $invokeParams = @{ Context = $C }
            if ($EnableVerbose) {
                $invokeParams.Verbose = $true
            }
            $null = Invoke-AvmTerraformLint @invokeParams

            Should -Invoke Invoke-AvmProcess -Exactly 3 -ParameterFilter {
                [bool]$StreamOutput
            }
        }
    }

    It 'copies a clean tree and removes the temporary lint stage' {
        $ctx = $script:context
        $cache = $script:lintCache
        $terraformDir = Join-Path $script:moduleDir '.terraform'
        New-Item -ItemType Directory -Path $terraformDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $terraformDir 'plugin.bin') -Value 'cached' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir '.terraform.lock.hcl') -Value 'lock' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'terraform.tfstate') -Value '{}' -Encoding utf8

        $probe = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; Cache = $cache } {
            param($C, $Cache)
            $script:artifactCount = -1
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter {
                $ArgumentList.Count -gt 0 -and $ArgumentList[0] -eq 'init'
            } {
                $script:artifactCount = @(
                    '.terraform'
                    '.terraform.lock.hcl'
                    'terraform.tfstate'
                ) | Where-Object { Test-Path -LiteralPath (Join-Path $WorkingDirectory $_) } |
                    Measure-Object |
                    Select-Object -ExpandProperty Count
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            $result = Invoke-AvmTerraformLint -Context $C
            [pscustomobject]@{
                ArtifactCount = $script:artifactCount
                Result = $result
                StageChildren = @(Get-ChildItem -LiteralPath (Join-Path $Cache 'lint-stage') -Force).Count
            }
        }

        $probe.Result.Status | Should -Be 'pass'
        $probe.ArtifactCount | Should -Be 0
        $probe.StageChildren | Should -Be 0
        Join-Path $script:moduleDir '.terraform.lock.hcl' | Should -Exist
        Join-Path $script:moduleDir 'terraform.tfstate' | Should -Exist
        Join-Path $terraformDir 'plugin.bin' | Should -Exist
    }

    It 'uses a root override to build a temporary merged config and removes it afterward' {
        $ctx = $script:context
        $configDir = Join-Path $TestDrive 'override-configs'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        foreach ($name in @('avm.tflint.hcl', 'avm.tflint_example.hcl', 'avm.tflint_module.hcl')) {
            @'
rule "managed_identities" {
  enabled = true
}
'@ | Set-Content -LiteralPath (Join-Path $configDir $name) -Encoding utf8
        }
        @'
rule "managed_identities" {
  enabled = false
}
'@ | Set-Content -LiteralPath (Join-Path $script:moduleDir 'avm.tflint.override.hcl') -Encoding utf8

        $capture = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; Config = $configDir; Cache = $TestDrive } {
            param($C, $Config, $Cache)
            $script:capturedConfigPath = $null
            $script:capturedConfigText = $null
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
            }
            Mock Resolve-AvmTflintConfigDir { $Config }
            Mock Get-AvmFolder { $Cache }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                $configIndex = [array]::IndexOf($ArgumentList, '--config') + 1
                $script:capturedConfigPath = $ArgumentList[$configIndex]
                $script:capturedConfigText = Get-Content -LiteralPath $script:capturedConfigPath -Raw
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            $result = Invoke-AvmTerraformLint -Context $C
            [pscustomobject]@{
                Result     = $result
                ConfigPath = $script:capturedConfigPath
                ConfigText = $script:capturedConfigText
            }
        }

        $capture.Result.Status | Should -Be 'pass'
        $capture.ConfigText | Should -Match 'enabled = false'
        $capture.ConfigPath | Should -Not -BeLike "$configDir*"
        $capture.ConfigPath | Should -Not -Exist
    }

    It 'applies the module and example rulesets to nested scopes' {
        $ctx = $script:context
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir (Join-Path 'modules' 'foo')) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir (Join-Path 'modules' (Join-Path 'foo' 'main.tf'))) -Value 'output "o" { value = 1 }' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir (Join-Path 'examples' 'default')) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir (Join-Path 'examples' (Join-Path 'default' 'main.tf'))) -Value 'module "m" {}' -Encoding utf8

        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            $result = Invoke-AvmTerraformLint -Context $C
            $result.Status | Should -Be 'pass'
            # 3 scopes: root (2 tf) + modules/foo (1 tf) + examples/default (1 tf).
            $result.FilesProcessed | Should -Be 4

            Should -Invoke Invoke-AvmProcess -Exactly 3 -ParameterFilter { $ArgumentList -contains '--init' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                ($ArgumentList -contains '--format=json') -and (($ArgumentList -join '|') -like '*avm.tflint_module.hcl*')
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                ($ArgumentList -contains '--format=json') -and (($ArgumentList -join '|') -like '*avm.tflint_example.hcl*')
            }
        }
    }

    It 'rejects example shell hooks even when a PowerShell sibling exists' {
        $ctx = $script:context
        $exampleDir = Join-Path $script:moduleDir 'examples/default'
        New-Item -ItemType Directory -Path $exampleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $exampleDir 'main.tf') -Value 'module "m" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $exampleDir 'tflint-pre.sh') -Value '#!/bin/sh' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $exampleDir 'tflint-pre.ps1') -Value '$null = 1' -Encoding utf8

        $probe = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            try {
                $null = Invoke-AvmTerraformLint -Context $C
            }
            catch {
                [pscustomobject]@{
                    ErrorName = $_.Exception.GetType().Name
                    Message = $_.Exception.Message
                }
            }

            Should -Invoke Invoke-AvmProcess -Exactly 0
        }

        $probe.ErrorName | Should -Be 'AvmConfigurationException'
        $probe.Message | Should -Match 'Refactor'
        $probe.Message | Should -Match '\.ps1'
    }

    It 'runs an example PowerShell pre-hook before TFLint' {
        $ctx = $script:context
        $exampleDir = Join-Path $script:moduleDir 'examples/default'
        New-Item -ItemType Directory -Path $exampleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $exampleDir 'main.tf') -Value 'module "m" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $exampleDir 'tflint-pre.ps1') -Value '$null = 1' -Encoding utf8

        $sequence = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; E = $exampleDir } {
            param($C, $E)
            $script:sequence = @()
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter {
                $ArgumentList.Count -gt 0 -and $ArgumentList[0] -eq 'init'
            } {
                if (($WorkingDirectory -replace '\\', '/') -like '*/examples/default') {
                    $script:sequence += 'terraform-init'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '-File' } {
                if (($WorkingDirectory -replace '\\', '/') -like '*/examples/default') {
                    $script:sequence += 'tflint-pre.ps1'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                if (($WorkingDirectory -replace '\\', '/') -like '*/examples/default') {
                    $script:sequence += 'tflint-init'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                if (($WorkingDirectory -replace '\\', '/') -like '*/examples/default') {
                    $script:sequence += 'tflint'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            $null = Invoke-AvmTerraformLint -Context $C

            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                ($ArgumentList -contains '-File') -and
                ($ArgumentList[-1] -like '*tflint-pre.ps1') -and
                $WorkingDirectory -ne $E -and
                (($WorkingDirectory -replace '\\', '/') -like '*/examples/default')
            }
            $script:sequence
        }

        $sequence | Should -Be @('terraform-init', 'tflint-pre.ps1', 'tflint-init', 'tflint')
    }

    It 'tags issue filenames with the scope relative path for nested scopes' {
        $ctx = $script:context
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir (Join-Path 'modules' 'foo')) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir (Join-Path 'modules' (Join-Path 'foo' 'main.tf'))) -Value 'output "o" { value = 1 }' -Encoding utf8

        $json = @'
{ "issues": [ { "rule": { "name": "terraform_unused_declarations", "severity": "warning" }, "message": "unused", "range": { "filename": "main.tf", "start": { "line": 3, "column": 1 } } } ] }
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            # Only the module scope reports an issue; the root scope is clean.
            Mock Invoke-AvmProcess -ParameterFilter {
                ($ArgumentList -contains '--format=json') -and (($ArgumentList -join '|') -like '*avm.tflint_module.hcl*')
            } { [pscustomobject]@{ ExitCode = 2; StdOut = $J; StdErr = '' } }
            Mock Invoke-AvmProcess -ParameterFilter {
                ($ArgumentList -contains '--format=json') -and (($ArgumentList -join '|') -like '*avm.tflint.hcl*')
            } { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformLint -Context $C
        }
        $result.Status         | Should -Be 'fail'
        $result.Issues.Count   | Should -Be 1
        $result.Issues[0].File  | Should -Be 'modules/foo/main.tf'
        $result.Issues[0].Scope | Should -Be 'modules/foo'
        $result.Issues[0].Line  | Should -Be 3
    }

    It 'fails on a warning-severity issue by default (F17)' {
        $ctx = $script:context
        $json = @'
{ "issues": [ { "rule": { "name": "terraform_deprecated_interpolation", "severity": "warning" }, "message": "deprecated", "range": { "filename": "main.tf", "start": { "line": 1, "column": 1 } } } ] }
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                [pscustomobject]@{ ExitCode = 2; StdOut = $J; StdErr = '' }
            }
            Invoke-AvmTerraformLint -Context $C
        }
        $result.Status             | Should -Be 'fail'
        $result.Issues[0].Severity | Should -Be 'warning'
    }

    It 'passes when only notice issues exist at the default threshold, fails when threshold is notice' {
        $ctx = $script:context
        $json = @'
{ "issues": [ { "rule": { "name": "terraform_comment_syntax", "severity": "notice" }, "message": "note", "range": { "filename": "main.tf", "start": { "line": 1, "column": 1 } } } ] }
'@
        $atDefault = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                [pscustomobject]@{ ExitCode = 2; StdOut = $J; StdErr = '' }
            }
            Invoke-AvmTerraformLint -Context $C
        }
        $atDefault.Status | Should -Be 'pass'

        $atNotice = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                [pscustomobject]@{ ExitCode = 2; StdOut = $J; StdErr = '' }
            }
            $r = Invoke-AvmTerraformLint -Context $C -MinimumFailureSeverity notice

            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList -contains '--minimum-failure-severity=notice'
            }
            $r
        }
        $atNotice.Status | Should -Be 'fail'
    }

    It 'fails on an error-severity issue even at the error threshold' {
        $ctx = $script:context
        $json = @'
{ "issues": [ { "rule": { "name": "terraform_required_version", "severity": "error" }, "message": "boom", "range": { "filename": "main.tf", "start": { "line": 5, "column": 3 } } } ] }
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                [pscustomobject]@{ ExitCode = 2; StdOut = $J; StdErr = '' }
            }
            Invoke-AvmTerraformLint -Context $C -MinimumFailureSeverity error
        }
        $result.Status             | Should -Be 'fail'
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].Line     | Should -Be 5
        $result.Issues[0].Column   | Should -Be 3
    }

    It 'passes a clean scope with no issues' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
            }
            Mock Resolve-AvmTflintConfigDir { '/cfg' }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformLint -Context $C
        }
        $result.Status       | Should -Be 'pass'
        $result.Issues.Count | Should -Be 0
    }

    It 'throws AvmProcessException when tflint --init fails' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
                }
                Mock Resolve-AvmTflintConfigDir { '/cfg' }
                Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                    [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'plugin download failed' }
                }
                Invoke-AvmTerraformLint -Context $C
            }
        }
        catch { $err = $_.Exception }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'plugin download failed'
    }

    It 'throws AvmProcessException on unexpected tflint lint exit codes' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
                }
                Mock Resolve-AvmTflintConfigDir { '/cfg' }
                Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                    [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                    [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'tflint blew up' }
                }
                Invoke-AvmTerraformLint -Context $C
            }
        }
        catch { $err = $_.Exception }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'tflint blew up'
    }

    It 'throws AvmProcessException on malformed tflint JSON' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{ Name = 'tflint'; Version = '0.55.1'; Source = 'cache'; Path = '/fake/tflint' }
                }
                Mock Resolve-AvmTflintConfigDir { '/cfg' }
                Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--init' } {
                    [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                Mock Invoke-AvmProcess -ParameterFilter { $ArgumentList -contains '--format=json' } {
                    [pscustomobject]@{ ExitCode = 2; StdOut = 'not json {'; StdErr = '' }
                }
                Invoke-AvmTerraformLint -Context $C
            }
        }
        catch { $err = $_.Exception }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'parse tflint'
    }
}
