#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTerraformTestSuite' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("tf-suite-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'tests' 'unit') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'tests' 'unit' 'main.tftest.hcl') -Value 'run "x" {}' -Encoding utf8

        $script:context = [pscustomobject][ordered]@{
            Kind      = 'terraform-module-repo'
            Root      = $script:moduleDir
            Ecosystem = 'terraform'
            Source    = 'path-heuristic'
        }
    }

    It 'rejects a non-terraform context' {
        $bicepCtx = [pscustomobject][ordered]@{
            Kind = 'bicep-module'; Root = $TestDrive; Ecosystem = 'bicep'; Source = 'path-heuristic'
        }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $bicepCtx } {
                param($C)
                Invoke-AvmTerraformTestSuite -Context $C -Tier unit
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'returns a clean pass with FilesProcessed=0 and never shells out when the tier ships no tftest files' {
        $emptyDir = Join-Path $TestDrive ("tf-empty-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        $ctx = [pscustomobject][ordered]@{
            Kind = 'terraform-module-repo'; Root = $emptyDir; Ecosystem = 'terraform'; Source = 'path-heuristic'
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess { throw 'should not shell out' }
            Invoke-AvmTerraformTestSuite -Context $C -Tier unit
        }
        $result.Status         | Should -Be 'skipped'
        $result.FilesProcessed | Should -Be 0
        $result.Issues         | Should -BeNullOrEmpty

        # F40: a tier with no test files must not report 'pass'. Inside a gauntlet
        # a pass is indistinguishable from a real one, so a module that ships no
        # tests stays green forever - the C01 shape, one level up.
        # F38: it must still carry run counts, so the empty case is not
        # shape-indistinguishable from a real run either.
        $result.PSObject.Properties.Name | Should -Contain 'RunsTotal'
        $result.PSObject.Properties.Name | Should -Contain 'RunsPassed'
        $result.PSObject.Properties.Name | Should -Contain 'RunsFailed'
        $result.RunsTotal      | Should -Be 0
        $result.RunsPassed     | Should -Be 0
        $result.RunsFailed     | Should -Be 0

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Times 0
        }
    }

    It 'auto-inits then runs terraform test and returns pass; FilesProcessed counts tftest files' {
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'tests' 'unit' 'extra.tftest.hcl') -Value 'run "y" {}' -Encoding utf8
        $ctx = $script:context
        $passJson = '{"@level":"info","type":"test_run","test_run":{"path":"tests/unit/main.tftest.hcl","run":"x","status":"pass"}}'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $passJson } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                if ($ArgumentList[0] -eq 'test') { return [pscustomobject]@{ ExitCode = 0; StdOut = $J; StdErr = '' } }
                throw "unexpected args: $($ArgumentList -join ' ')"
            }
            Invoke-AvmTerraformTestSuite -Context $C -Tier unit
        }
        $result.Status         | Should -Be 'pass'
        $result.Engine         | Should -Be 'terraform'
        $result.Tool           | Should -Be 'terraform/1.15.3'
        $result.ToolPath       | Should -Be '/fake/terraform'
        $result.ToolSource     | Should -Be 'cache'
        $result.FilesProcessed | Should -Be 2
        $result.Issues         | Should -BeNullOrEmpty

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'init' -and $ArgumentList -contains '-backend=false'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'test' -and $ArgumentList -contains '-json' -and
                ($ArgumentList -contains '-test-directory=tests/unit')
            }
        }
    }

    It 'passes the integration tier directory through to -test-directory' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'tests' 'integration') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'tests' 'integration' 'it.tftest.hcl') -Value 'run "z" {}' -Encoding utf8
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            $null = Invoke-AvmTerraformTestSuite -Context $C -Tier integration

            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'test' -and
                ($ArgumentList -contains '-test-directory=tests/integration') -and
                $StreamOutput
            }
        }
    }

    It 'F32: still runs init when .terraform/ already exists, so new module dependencies resolve' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir '.terraform') -Force | Out-Null
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            $null = Invoke-AvmTerraformTestSuite -Context $C -Tier unit

            Should -Invoke Invoke-AvmProcess -Exactly 2
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'init' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'test' }
        }
    }

    It 'F34: passes -test-directory to terraform init so run-block modules are installed' -ForEach @(
        @{ Tier = 'unit' }
        @{ Tier = 'integration' }
    ) {
        $tierDir = Join-Path $script:moduleDir 'tests' $Tier
        New-Item -ItemType Directory -Path $tierDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tierDir 'f34.tftest.hcl') -Value 'run "z" {}' -Encoding utf8
        $ctx = $script:context
        $initArgs = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; T = $Tier } {
            param($C, $T)
            $captured = New-Object System.Collections.Generic.List[object]
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'init') { $captured.AddRange([object[]]$ArgumentList) }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            $null = Invoke-AvmTerraformTestSuite -Context $C -Tier $T
            , $captured.ToArray()
        }

        $initArgs | Should -Contain ('-test-directory=tests/{0}' -f $Tier)
    }

    It 'honours -NoInit and skips terraform init even when .terraform/ is absent' {
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            $null = Invoke-AvmTerraformTestSuite -Context $C -Tier unit -NoInit

            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -eq 'init' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'test' }
        }
    }

    It 'marks Status=fail and records an issue when a test_run fails' {
        $ctx = $script:context
        $failJson = @'
{"@level":"info","type":"test_run","test_run":{"path":"tests/unit/main.tftest.hcl","run":"valid_input","status":"fail"}}
{"@level":"info","type":"test_summary","test_summary":{"status":"fail","passed":0,"failed":1,"errored":0,"skipped":0}}
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $failJson } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                [pscustomobject]@{ ExitCode = 1; StdOut = $J; StdErr = '' }
            }
            Invoke-AvmTerraformTestSuite -Context $C -Tier unit
        }
        $result.Status             | Should -Be 'fail'
        $result.Issues.Count       | Should -Be 1
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].File     | Should -Be 'tests/unit/main.tftest.hcl'
        $result.Issues[0].Message  | Should -Match "valid_input"
    }

    It 'surfaces an error diagnostic with file/line/column from its range' {
        $ctx = $script:context
        $diagJson = @'
{"@level":"error","type":"diagnostic","diagnostic":{"severity":"error","summary":"Invalid reference","detail":"a bad thing","range":{"filename":"tests/unit/main.tftest.hcl","start":{"line":7,"column":3}}}}
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $diagJson } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                [pscustomobject]@{ ExitCode = 1; StdOut = $J; StdErr = '' }
            }
            Invoke-AvmTerraformTestSuite -Context $C -Tier unit
        }
        $result.Status             | Should -Be 'fail'
        $result.Issues.Count       | Should -Be 1
        $result.Issues[0].File     | Should -Be 'tests/unit/main.tftest.hcl'
        $result.Issues[0].Line     | Should -Be 7
        $result.Issues[0].Column   | Should -Be 3
        $result.Issues[0].Message  | Should -Match 'Invalid reference'
    }

    It 'throws AvmProcessException when terraform init itself fails' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/terraform'
                    }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'init boom' } }
                Invoke-AvmTerraformTestSuite -Context $C -Tier unit
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'init boom'
    }

    It 'throws AvmProcessException when terraform test exits with an unexpected code' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/terraform'
                    }
                }
                Mock Invoke-AvmProcess {
                    param($FilePath, $ArgumentList)
                    if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                    [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'internal error' }
                }
                Invoke-AvmTerraformTestSuite -Context $C -Tier unit
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'internal error'
    }

    It 'fans out over modules/* submodules, aggregates FilesProcessed and prefixes submodule issue paths' {
        $subDir = Join-Path $script:moduleDir 'modules' 'foo'
        New-Item -ItemType Directory -Path (Join-Path $subDir 'tests' 'unit') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $subDir 'tests' 'unit' 'sub.tftest.hcl') -Value 'run "s" {}' -Encoding utf8
        $ctx = $script:context
        $passJson = '{"type":"test_run","test_run":{"path":"tests/unit/main.tftest.hcl","run":"x","status":"pass"}}'
        $subJson = '{"type":"test_run","test_run":{"path":"tests/unit/sub.tftest.hcl","run":"s","status":"fail"}}'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; PassJson = $passJson; SubJson = $subJson } {
            param($C, $PassJson, $SubJson)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList, $WorkingDirectory)
                if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                if ((Split-Path $WorkingDirectory -Leaf) -eq 'foo') { return [pscustomobject]@{ ExitCode = 1; StdOut = $SubJson; StdErr = '' } }
                [pscustomobject]@{ ExitCode = 0; StdOut = $PassJson; StdErr = '' }
            }
            Invoke-AvmTerraformTestSuite -Context $C -Tier unit
        }
        $result.Status         | Should -Be 'fail'
        $result.FilesProcessed | Should -Be 2
        $result.Issues.Count   | Should -Be 1
        $result.Issues[0].File | Should -Be 'modules/foo/tests/unit/sub.tftest.hcl'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter { $ArgumentList[0] -eq 'test' }
        }
    }

    It 'runs an isolated setup.ps1 hook before terraform' {
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'tests' 'unit' 'setup.ps1') -Value '"noop"' -Encoding utf8
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            $null = Invoke-AvmTerraformTestSuite -Context $C -Tier unit

            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                ($ArgumentList -contains '-NoProfile') -and ($ArgumentList -contains '-File') -and
                ($ArgumentList[-1] -like '*setup.ps1')
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'test' }
        }
    }

    It 'records an issue and skips terraform when setup.ps1 fails' {
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'tests' 'unit' 'setup.ps1') -Value 'exit 3' -Encoding utf8
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                if ($ArgumentList -contains '-File') { return [pscustomobject]@{ ExitCode = 3; StdOut = ''; StdErr = 'setup boom' } }
                throw 'terraform should not run when setup.ps1 fails'
            }
            Invoke-AvmTerraformTestSuite -Context $C -Tier unit
        }
        $result.Status            | Should -Be 'fail'
        $result.Issues.Count      | Should -Be 1
        $result.Issues[0].File    | Should -Be 'tests/unit/setup.ps1'
        $result.Issues[0].Message | Should -Match 'setup.ps1 hook failed'
        $result.Issues[0].Message | Should -Match 'setup boom'
    }

    It 'throws AvmConfigurationException when a shell hook has no PowerShell counterpart' {
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'tests' 'unit' 'setup.sh') -Value 'echo hi' -Encoding utf8
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/terraform'
                    }
                }
                Mock Invoke-AvmProcess { throw 'should not shell out' }
                Invoke-AvmTerraformTestSuite -Context $C -Tier unit
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message        | Should -Match 'setup.sh'
        $err.Message        | Should -Match '\.ps1'
    }

    # F39: upstream AVM governance ships setup.sh and setup.ps1 side by side, so
    # rejecting the mere presence of a .sh made `avm test unit` throw on every
    # governance-compliant module. Only a .sh with no .ps1 counterpart is a
    # misconfiguration, because only then does the hook silently never run.
    It 'F39: accepts a shell hook that has a PowerShell counterpart' {
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'tests' 'unit' 'setup.sh') -Value 'echo hi' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'tests' 'unit' 'setup.ps1') -Value 'exit 0' -Encoding utf8
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTestSuite -Context $C -Tier unit
        }
        $result.Status | Should -Be 'pass'
    }

    It 'skips a modules/* subdirectory that ships no tests for the tier' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'modules' 'empty') -Force | Out-Null
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTestSuite -Context $C -Tier unit
        }
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 1

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'test' }
        }
    }

    It 'F33: reports run counts, not just file counts' {
        $ctx = $script:context
        $json = @(
            '{"@level":"info","type":"test_run","test_run":{"path":"tests/unit/main.tftest.hcl","run":"a","status":"pass"}}'
            '{"@level":"info","type":"test_run","test_run":{"path":"tests/unit/main.tftest.hcl","run":"b","status":"pass"}}'
            '{"@level":"info","type":"test_run","test_run":{"path":"tests/unit/main.tftest.hcl","run":"c","status":"fail"}}'
        ) -join "`n"
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                [pscustomobject]@{ ExitCode = 1; StdOut = $J; StdErr = '' }
            }
            Invoke-AvmTerraformTestSuite -Context $C -Tier unit
        }

        $result.FilesProcessed | Should -Be 1
        $result.RunsTotal      | Should -Be 3
        $result.RunsPassed     | Should -Be 2
        $result.RunsFailed     | Should -Be 1
    }

    It 'F33: reports zero runs for a vacuous suite that never executes a run' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTestSuite -Context $C -Tier unit
        }

        $result.Status    | Should -Be 'pass'
        $result.RunsTotal | Should -Be 0
    }

    It 'F33: both tiers invoke terraform test identically and never stream raw json' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'tests' 'integration') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'tests' 'integration' 'deploy.tftest.hcl') -Value 'run "z" {}' -Encoding utf8
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }

            $null = Invoke-AvmTerraformTestSuite -Context $C -Tier unit
            $null = Invoke-AvmTerraformTestSuite -Context $C -Tier integration

            # A stdout hook means the engine owns rendering, so raw NDJSON never
            # reaches the human channel on either tier.
            Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter {
                $ArgumentList[0] -eq 'test' -and $StreamOutput -and $null -ne $OnStdOutLine
            }
        }
    }

    It 'F33: Read-AvmTerraformTestRunEvent parses terminal run events and ignores everything else' {
        InModuleScope 'Avm.Authoring' {
            $passed = Read-AvmTerraformTestRunEvent -Line '{"@level":"info","type":"test_run","test_run":{"path":"tests/unit/main.tftest.hcl","run":"a","status":"pass"}}'
            $passed.Name   | Should -Be 'a'
            $passed.Path   | Should -Be 'tests/unit/main.tftest.hcl'
            $passed.Status | Should -Be 'pass'

            Read-AvmTerraformTestRunEvent -Line '' | Should -BeNullOrEmpty
            Read-AvmTerraformTestRunEvent -Line 'not json at all' | Should -BeNullOrEmpty
            Read-AvmTerraformTestRunEvent -Line '{"@level":"info","type":"test_file","test_file":{}}' | Should -BeNullOrEmpty
            Read-AvmTerraformTestRunEvent -Line '{"@level":"info","type":"test_run","test_run":{"run":"a","status":"running"}}' | Should -BeNullOrEmpty
        }
    }

    It 'F33: the progress hook resolves module-private helpers when invoked from Invoke-AvmProcess' {
        $ctx = $script:context
        $json = '{"@level":"info","type":"test_run","test_run":{"path":"tests/unit/main.tftest.hcl","run":"a","status":"pass"}}'
        $rendered = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            $script:avmProgressLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-AvmLog { param($Message) $script:avmProgressLines.Add([string]$Message) }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList, $OnStdOutLine)
                if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                if ($null -ne $OnStdOutLine) { & $OnStdOutLine $J }
                [pscustomobject]@{ ExitCode = 0; StdOut = $J; StdErr = '' }
            }
            $null = Invoke-AvmTerraformTestSuite -Context $C -Tier unit
            , $script:avmProgressLines.ToArray()
        }

        ($rendered -join "`n") | Should -Match 'run tests/unit/main\.tftest\.hcl "a" -> pass'
    }
}
