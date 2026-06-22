#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmBicepTest' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("bicep-mod-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        $script:fileA = Join-Path $script:moduleDir 'main.bicep'
        $script:fileB = Join-Path $script:moduleDir 'nested.bicep'
        $script:fileC = Join-Path $script:moduleDir 'main.bicepparam'  # skipped (build = .bicep only)
        Set-Content -LiteralPath $script:fileA -Value 'param x string' -Encoding utf8
        Set-Content -LiteralPath $script:fileB -Value 'param y string' -Encoding utf8
        Set-Content -LiteralPath $script:fileC -Value "using './main.bicep'" -Encoding utf8

        $script:context = [pscustomobject][ordered]@{
            Kind = 'bicep-module'; Root = $script:moduleDir; Ecosystem = 'bicep'; Source = 'path-heuristic'
        }
    }

    It 'rejects a non-bicep context' {
        $tfCtx = [pscustomobject][ordered]@{
            Kind = 'terraform-module-repo'; Root = $script:moduleDir; Ecosystem = 'terraform'; Source = 'path-heuristic'
        }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $tfCtx } {
                param($C)
                Invoke-AvmBicepTest -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'invokes bicep build --stdout once per .bicep file' {
        $ctx = $script:context
        $captured = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            $script:calls = New-Object System.Collections.Generic.List[object]
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $script:calls.Add([pscustomobject]@{ FilePath = $FilePath; Args = $ArgumentList })
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            $r = Invoke-AvmBicepTest -Context $C
            [pscustomobject]@{ Result = $r; Calls = $script:calls }
        }
        $captured.Result.FilesProcessed | Should -Be 2
        $captured.Calls.Count            | Should -Be 2
        $captured.Calls[0].Args[0]       | Should -Be 'build'
        $captured.Calls[0].Args[1]       | Should -Be '--stdout'
    }

    It 'parses compile errors and flips Status to fail' {
        $ctx = $script:context
        $a = $script:fileA
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; A = $a } {
            param($C, $A)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $target = $ArgumentList[2]
                if ($target -eq $A) {
                    return [pscustomobject]@{
                        ExitCode = 1
                        StdOut   = ''
                        StdErr   = "$A(2,1) : Error BCP018: Expected the ""="" character at this location."
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
            }
            Invoke-AvmBicepTest -Context $C
        }
        $result.Status               | Should -Be 'fail'
        $result.Issues.Count         | Should -Be 1
        $result.Issues[0].Severity   | Should -Be 'error'
        $result.Issues[0].Code       | Should -Be 'BCP018'
    }

    It 'returns Status=pass when only warnings are emitted' {
        $ctx = $script:context
        $a = $script:fileA
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; A = $a } {
            param($C, $A)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $target = $ArgumentList[2]
                if ($target -eq $A) {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = '{}'
                        StdErr   = "$A(3,5) : Warning no-unused-params: Parameter ""x"" is declared but never used."
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
            }
            Invoke-AvmBicepTest -Context $C
        }
        $result.Status             | Should -Be 'pass'
        $result.Issues.Count       | Should -Be 1
        $result.Issues[0].Severity | Should -Be 'warning'
    }

    It 'reports the bicep tool identity in the returned object' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' } }
            Invoke-AvmBicepTest -Context $C
        }
        $result.Engine     | Should -Be 'bicep'
        $result.Tool       | Should -Be 'bicep/0.30.3'
        $result.ToolPath   | Should -Be '/fake/bicep'
        $result.ToolSource | Should -Be 'cache'
    }
}
