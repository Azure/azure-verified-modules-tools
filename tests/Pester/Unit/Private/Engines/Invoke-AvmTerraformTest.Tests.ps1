#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
    $script:savedRunnerDebug = $env:RUNNER_DEBUG
    $script:savedAvmVerbose = $env:AVM_VERBOSE
}

AfterAll {
    $env:RUNNER_DEBUG = $script:savedRunnerDebug
    $env:AVM_VERBOSE = $script:savedAvmVerbose
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTerraformTest' {
    BeforeEach {
        $env:RUNNER_DEBUG = ''
        $env:AVM_VERBOSE = ''
        InModuleScope 'Avm.Authoring' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) 'avm-validation-unit'
            $example = Join-Path $root 'examples' 'default'
            $script:validationContext = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $root; Ecosystem = 'terraform'
            }
            $script:validationScope = [pscustomobject]@{
                Examples = @([pscustomobject]@{
                        Path = $example; RelativePath = 'examples/default'
                        Files = @((Join-Path $example 'main.tf'), (Join-Path $example 'terraform.tf'))
                        TestFiles = @()
                    })
                Modules = @([pscustomobject]@{
                        Path = $root; RelativePath = '.'
                        Files = @((Join-Path $root 'main.tf'), (Join-Path $root 'outputs.tf'))
                    })
            }
            $script:validationJson = '{"valid":true,"diagnostics":[]}'
            $script:validationExitCode = 0
            $script:validationManifest = '{"Modules":[{"Key":"","Dir":"."},{"Key":"subject","Dir":"../.."}]}'
            $script:validationDataDirectories = [System.Collections.Generic.List[string]]::new()

            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.8'; Source = 'cache'; Path = 'terraform-stub'
                }
            }
            Mock Get-AvmTerraformValidationScope { $script:validationScope }
            Mock New-Item {
                $script:validationDataDirectories.Add($Path)
            }
            Mock Test-Path { $true }
            Mock Remove-Item {}
            Mock Write-AvmLog {}
            Mock Get-Content { $script:validationManifest }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'init') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                if ($ArgumentList[0] -eq 'validate') {
                    return [pscustomobject]@{
                        ExitCode = $script:validationExitCode; StdOut = $script:validationJson; StdErr = ''
                    }
                }
                throw "Unexpected Terraform arguments: $($ArgumentList -join ' ')"
            }
        }
    }

    It 'rejects a non-Terraform context' {
        InModuleScope 'Avm.Authoring' {
            $script:validationContext.Ecosystem = 'bicep'
            { Invoke-AvmTerraformTest -Context $script:validationContext } |
                Should -Throw -ExceptionType ([System.ArgumentException])
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }

    It 'initializes and validates the example instead of the library root' {
        InModuleScope 'Avm.Authoring' {
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'pass'
            $result.Engine | Should -Be 'terraform'
            $result.Tool | Should -Be 'terraform/1.15.8'
            $result.ToolPath | Should -Be 'terraform-stub'
            $result.ToolSource | Should -Be 'cache'
            $result.FilesProcessed | Should -Be 2
            $result.Issues | Should -BeNullOrEmpty

            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'init' -and
                $ArgumentList -contains '-backend=false' -and
                $ArgumentList -contains '-upgrade' -and
                $ArgumentList -contains '-input=false' -and
                $WorkingDirectory -eq $script:validationScope.Examples[0].Path -and
                -not [bool]$StreamOutput
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'validate' -and $ArgumentList -contains '-json' -and
                $WorkingDirectory -eq $script:validationScope.Examples[0].Path
            }
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter {
                $WorkingDirectory -eq $script:validationContext.Root
            }
            Should -Invoke Remove-Item -Exactly 1
        }
    }

    It 'uses a separate fresh data directory per example and shares it between init and validate' {
        InModuleScope 'Avm.Authoring' {
            $second = Join-Path $script:validationContext.Root 'examples' 'second'
            $script:validationScope.Examples += [pscustomobject]@{
                Path = $second; RelativePath = 'examples/second'; Files = @((Join-Path $second 'main.tf')); TestFiles = @()
            }
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'pass'
            $result.FilesProcessed | Should -Be 3
            $result.Issues | Should -BeNullOrEmpty
            @($script:validationDataDirectories | Select-Object -Unique).Count | Should -Be 2

            Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter {
                $WorkingDirectory -eq $script:validationScope.Examples[0].Path -and
                $EnvVars.TF_DATA_DIR -eq $script:validationDataDirectories[0]
            }
            Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter {
                $WorkingDirectory -eq $script:validationScope.Examples[1].Path -and
                $EnvVars.TF_DATA_DIR -eq $script:validationDataDirectories[1]
            }
            Should -Invoke Get-Content -Exactly 1 -ParameterFilter {
                $LiteralPath -eq (Join-Path $script:validationDataDirectories[0] 'modules' 'modules.json')
            }
            Should -Invoke Get-Content -Exactly 1 -ParameterFilter {
                $LiteralPath -eq (Join-Path $script:validationDataDirectories[1] 'modules' 'modules.json')
            }
            Should -Invoke Remove-Item -Exactly 2
        }
    }

    It 'streams initialization when <Mode> enables verbose logging' -TestCases @(
        @{ Mode = '-Verbose'; RunnerDebug = ''; UseVerbose = $true }
        @{ Mode = 'GitHub Actions debug mode'; RunnerDebug = '1'; UseVerbose = $false }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ DebugValue = $RunnerDebug; EnableVerbose = $UseVerbose } {
            param($DebugValue, $EnableVerbose)
            $env:RUNNER_DEBUG = $DebugValue
            $null = Invoke-AvmTerraformTest -Context $script:validationContext -Verbose:$EnableVerbose
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'init' -and [bool]$StreamOutput
            }
        }
    }

    It 'warns rather than claims coverage when initialization is explicitly skipped' {
        InModuleScope 'Avm.Authoring' {
            $result = Invoke-AvmTerraformTest -Context $script:validationContext -NoInit
            $result.Status | Should -Be 'pass'
            $result.FilesProcessed | Should -Be 2
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].Severity | Should -Be 'warning'
            $result.Issues[0].Code | Should -Be 'terraform.module-coverage-unavailable'
            $result.Issues[0].Message | Should -Match 'NoInit'
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -eq 'init' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'validate' -and -not $EnvVars.ContainsKey('TF_DATA_DIR')
            }
            Should -Invoke New-Item -Exactly 0
            Should -Invoke Get-Content -Exactly 0
            Should -Invoke Remove-Item -Exactly 0
            Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter { $Level -eq 'Warning' }
        }
    }

    It 'skips without running Terraform when no examples exist and warns about the root module' {
        InModuleScope 'Avm.Authoring' {
            $script:validationScope.Examples = @()
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'skipped'
            $result.FilesProcessed | Should -Be 0
            @($result.Issues | Where-Object Severity -eq 'warning').Count | Should -Be 2
            $result.Issues.Message -join ' ' | Should -Match 'No Terraform examples'
            $result.Issues.Message -join ' ' | Should -Match "module '\.'"
            Should -Invoke Invoke-AvmProcess -Exactly 0
            Should -Invoke New-Item -Exactly 0
        }
    }

    It 'warns only for the uncovered module without failing validation' {
        InModuleScope 'Avm.Authoring' {
            $uncovered = Join-Path $script:validationContext.Root 'modules' 'uncovered'
            $script:validationScope.Modules += [pscustomobject]@{
                Path = $uncovered; RelativePath = 'modules/uncovered'; Files = @((Join-Path $uncovered 'main.tf'))
            }
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'pass'
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].Severity | Should -Be 'warning'
            $result.Issues[0].Code | Should -Be 'terraform.module-coverage'
            $result.Issues[0].File | Should -Be 'modules/uncovered/main.tf'
            $result.Issues[0].Message | Should -Match 'modules/uncovered'
            Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter {
                $Level -eq 'Warning' -and $File -eq 'modules/uncovered/main.tf'
            }
        }
    }

    It 'counts a transitively referenced local submodule as covered' {
        InModuleScope 'Avm.Authoring' {
            $nested = Join-Path $script:validationContext.Root 'modules' 'nested'
            $script:validationScope.Modules += [pscustomobject]@{
                Path = $nested; RelativePath = 'modules/nested'; Files = @((Join-Path $nested 'main.tf'))
            }
            $script:validationManifest = @'
{"Modules":[
  {"Key":"","Dir":"."},
  {"Key":"subject","Dir":"../.."},
  {"Key":"subject.nested","Dir":"../../modules/nested"}
]}
'@
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'pass'
            $result.FilesProcessed | Should -Be 2
            $result.Issues | Should -BeNullOrEmpty
        }
    }

    It 'does not count a registry or Git cache copy as coverage of the checkout' {
        InModuleScope 'Avm.Authoring' {
            $script:validationManifest = '{"Modules":[{"Key":"","Dir":"."},{"Key":"subject","Dir":".terraform/modules/subject"}]}'
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'pass'
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].Code | Should -Be 'terraform.module-coverage'
            $result.Issues[0].Message | Should -Match "module '\.'"
        }
    }

    It 'does not count test-only module references as example coverage' {
        InModuleScope 'Avm.Authoring' {
            $script:validationManifest = '{"Modules":[{"Key":"","Dir":"."},{"Key":"test.tests/unit.setup","Dir":"../.."}]}'
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'pass'
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].Code | Should -Be 'terraform.module-coverage'
        }
    }

    It 'preserves non-failing Terraform deprecation warnings and rebases child diagnostic paths' {
        InModuleScope 'Avm.Authoring' {
            $script:validationJson = @'
{"valid":true,"diagnostics":[{
  "severity":"warning","summary":"Deprecated value used","detail":"Use the current output.",
  "range":{"filename":"../../outputs.tf","start":{"line":4,"column":3}}
}]}
'@
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'pass'
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].Severity | Should -Be 'warning'
            $result.Issues[0].File | Should -Be 'outputs.tf'
            $result.Issues[0].Line | Should -Be 4
            $result.Issues[0].Column | Should -Be 3
            $result.Issues[0].Message | Should -Match '\[examples/default\].*Deprecated'
        }
    }

    It 'continues validating remaining examples after an error and returns fail' {
        InModuleScope 'Avm.Authoring' {
            $second = Join-Path $script:validationContext.Root 'examples' 'second'
            $script:validationScope.Examples += [pscustomobject]@{
                Path = $second; RelativePath = 'examples/second'; Files = @((Join-Path $second 'main.tf')); TestFiles = @()
            }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'init') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                if ($WorkingDirectory -eq $script:validationScope.Examples[0].Path) {
                    return [pscustomobject]@{
                        ExitCode = 1; StdErr = ''
                        StdOut = '{"valid":false,"diagnostics":[{"severity":"error","summary":"Invalid reference","range":{"filename":"main.tf","start":{"line":3,"column":1}}}]}'
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = $script:validationJson; StdErr = '' }
            }
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'fail'
            $result.FilesProcessed | Should -Be 3
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].File | Should -Be 'examples/default/main.tf'
            $result.Issues[0].Line | Should -Be 3
            $result.Issues[0].Severity | Should -Be 'error'
            Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter { $ArgumentList[0] -eq 'validate' }
            Should -Invoke Remove-Item -Exactly 2
        }
    }

    It 'does not report success for <Scenario>' -TestCases @(
        @{ Scenario = 'a failing exit code with no diagnostics'; ExitCode = 1; Payload = '{"valid":true,"diagnostics":[]}' }
        @{ Scenario = 'a false valid flag with no diagnostics'; ExitCode = 0; Payload = '{"valid":false,"diagnostics":[]}' }
        @{ Scenario = 'an error diagnostic with a successful exit code'; ExitCode = 0; Payload = '{"valid":true,"diagnostics":[{"severity":"error","summary":"Invalid reference"}]}' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Code = $ExitCode; Json = $Payload } {
            param($Code, $Json)
            $script:validationExitCode = $Code
            $script:validationJson = $Json
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'fail'
            @($result.Issues | Where-Object Severity -eq 'error').Count | Should -Be 1
        }
    }

    It 'rejects invalid validation output: <Scenario>' -TestCases @(
        @{ Scenario = 'empty output'; Payload = '' }
        @{ Scenario = 'non-JSON output'; Payload = 'unexpected output' }
        @{ Scenario = 'missing valid'; Payload = '{"diagnostics":[]}' }
        @{ Scenario = 'missing diagnostics'; Payload = '{"valid":true}' }
        @{ Scenario = 'string valid'; Payload = '{"valid":"true","diagnostics":[]}' }
        @{ Scenario = 'malformed diagnostic'; Payload = '{"valid":true,"diagnostics":[{}]}' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Json = $Payload } {
            param($Json)
            $script:validationJson = $Json
            { Invoke-AvmTerraformTest -Context $script:validationContext } |
                Should -Throw -ExceptionType ([AvmProcessException])
            Should -Invoke Remove-Item -Exactly 1
        }
    }

    It 'warns without failing when the installed module manifest is malformed' {
        InModuleScope 'Avm.Authoring' {
            $script:validationManifest = '{'
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'pass'
            @($result.Issues | Where-Object Code -eq 'terraform.module-coverage-unavailable').Count | Should -Be 1
            @($result.Issues | Where-Object Severity -eq 'error').Count | Should -Be 0
            $result.Issues.Message -join ' ' | Should -Match 'valid JSON'
        }
    }

    It 'warns without failing when the installed module manifest is missing' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-Content { throw [System.Management.Automation.ItemNotFoundException]::new('No module manifest.') }
            $result = Invoke-AvmTerraformTest -Context $script:validationContext
            $result.Status | Should -Be 'pass'
            @($result.Issues | Where-Object Code -eq 'terraform.module-coverage-unavailable').Count | Should -Be 1
            $result.Issues.Message -join ' ' | Should -Match 'No module manifest'
        }
    }

    It 'throws an actionable initialization error and cleans temporary data' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'init boom' } }
            { Invoke-AvmTerraformTest -Context $script:validationContext } |
                Should -Throw -ExceptionType ([AvmProcessException]) -ExpectedMessage '*examples/default*init boom*'
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -eq 'validate' }
            Should -Invoke Remove-Item -Exactly 1
        }
    }

    It 'throws on an unexpected validation exit code and cleans temporary data' {
        InModuleScope 'Avm.Authoring' {
            $script:validationExitCode = 2
            { Invoke-AvmTerraformTest -Context $script:validationContext } |
                Should -Throw -ExceptionType ([AvmProcessException]) -ExpectedMessage '*examples/default*code 2*'
            Should -Invoke Remove-Item -Exactly 1
        }
    }

    It 'does not remove a data directory when creating it failed' {
        InModuleScope 'Avm.Authoring' {
            Mock New-Item { throw [System.IO.IOException]::new('The directory already exists.') }
            { Invoke-AvmTerraformTest -Context $script:validationContext } |
                Should -Throw -ExpectedMessage '*already exists*'
            Should -Invoke Invoke-AvmProcess -Exactly 0
            Should -Invoke Remove-Item -Exactly 0
        }
    }
}
