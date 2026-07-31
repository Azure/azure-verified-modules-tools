#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Format-AvmTerraformModule' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("tf-mod-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null

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
            Root      = $script:moduleDir
            Ecosystem = 'bicep'
            Source    = 'path-heuristic'
        }
        $bad = $bicepCtx
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $bad } {
                param($C)
                Format-AvmTerraformModule -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'invokes terraform fmt -recursive exactly once with the module root' {
        $ctx = $script:context
        $root = $script:moduleDir

        $captured = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $root } {
            param($C, $R)
            $captured = [pscustomobject]@{ Args = $null; FilePath = $null }
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $captured.FilePath = $FilePath
                $captured.Args = $ArgumentList
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Format-AvmTerraformModule -Context $C | Out-Null
            $captured
        }
        $captured.FilePath  | Should -Be '/fake/terraform'
        $captured.Args[0]   | Should -Be 'fmt'
        $captured.Args[1]   | Should -Be '-recursive'
        $captured.Args[-1]  | Should -Be $root

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1
        }
    }

    It 'parses terraform fmt -list output into the Changed array' {
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
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = "main.tf`nvariables.tf`n"
                    StdErr   = ''
                }
            }
            Format-AvmTerraformModule -Context $C
        }
        $result.Engine     | Should -Be 'terraform'
        $result.Tool       | Should -Be 'terraform/1.15.3'
        $result.ToolSource | Should -Be 'cache'
        $result.Changed.Count | Should -Be 2
        $result.Changed     | Should -Contain 'main.tf'
        $result.Changed     | Should -Contain 'variables.tf'
    }

    It 'returns an empty Changed array when terraform fmt prints nothing' {
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
            Format-AvmTerraformModule -Context $C
        }
        $result.Changed.Count | Should -Be 0
    }

    It 'writes by default and still reports pass when files were rewritten' {
        $ctx = $script:context
        $outcome = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            $captured = [pscustomobject]@{ Args = $null }
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $captured.Args = $ArgumentList
                [pscustomobject]@{ ExitCode = 0; StdOut = "main.tf`n"; StdErr = '' }
            }
            [pscustomobject]@{ Result = (Format-AvmTerraformModule -Context $C); Args = $captured.Args }
        }
        $outcome.Args | Should -Contain '-write=true'
        $outcome.Result.Status | Should -Be 'pass'
        $outcome.Result.Issues.Count | Should -Be 0
    }

    It 'does not write in drift mode' {
        $ctx = $script:context
        $captured = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            $captured = [pscustomobject]@{ Args = $null }
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $captured.Args = $ArgumentList
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Format-AvmTerraformModule -Context $C -CheckDrift | Out-Null
            $captured
        }
        $captured.Args | Should -Contain '-write=false'
        $captured.Args | Should -Not -Contain '-write=true'
    }

    It 'fails with one Issue per unformatted file in drift mode' {
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
                [pscustomobject]@{ ExitCode = 0; StdOut = "main.tf`nvariables.tf`n"; StdErr = '' }
            }
            Format-AvmTerraformModule -Context $C -CheckDrift
        }
        $result.Status | Should -Be 'fail'
        $result.Issues.Count | Should -Be 2
        $result.Issues[0].File | Should -Be 'main.tf'
        $result.Issues[0].Code | Should -Be 'avm.tf.fmt-drift'
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].Message | Should -Match "avm format"
    }

    It 'passes with no Issues in drift mode when everything is formatted' {
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
            Format-AvmTerraformModule -Context $C -CheckDrift
        }
        $result.Status | Should -Be 'pass'
        $result.Issues.Count | Should -Be 0
    }
}
