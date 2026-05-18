#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmBicepLint' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("bicep-mod-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        $script:fileA = Join-Path $script:moduleDir 'main.bicep'
        $script:fileB = Join-Path $script:moduleDir 'nested.bicep'
        $script:fileC = Join-Path $script:moduleDir 'main.bicepparam'  # should be skipped (lint = .bicep only)
        $script:fileD = Join-Path $script:moduleDir 'README.md'
        Set-Content -LiteralPath $script:fileA -Value 'param x string' -Encoding utf8
        Set-Content -LiteralPath $script:fileB -Value 'param y string' -Encoding utf8
        Set-Content -LiteralPath $script:fileC -Value "using './main.bicep'" -Encoding utf8
        Set-Content -LiteralPath $script:fileD -Value '# README' -Encoding utf8

        $script:context = [pscustomobject][ordered]@{
            Kind      = 'bicep-module'
            Root      = $script:moduleDir
            Ecosystem = 'bicep'
            Source    = 'path-heuristic'
        }
    }

    It 'rejects a non-bicep context' {
        $tfCtx = [pscustomobject][ordered]@{
            Kind      = 'terraform-module-repo'
            Root      = $script:moduleDir
            Ecosystem = 'terraform'
            Source    = 'path-heuristic'
        }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $tfCtx } {
                param($C)
                Invoke-AvmBicepLint -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'invokes bicep lint once per .bicep file (skips .bicepparam and .md)' {
        $ctx = $script:context
        $count = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            (Invoke-AvmBicepLint -Context $C).FilesProcessed
        }
        $count | Should -Be 2

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 2
        }
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
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmBicepLint -Context $C
        }
        $result.Engine     | Should -Be 'bicep'
        $result.Tool       | Should -Be 'bicep/0.30.3'
        $result.ToolPath   | Should -Be '/fake/bicep'
        $result.ToolSource | Should -Be 'cache'
        $result.Status     | Should -Be 'pass'
        $result.Issues     | Should -BeNullOrEmpty
    }

    It 'parses textual diagnostics into structured Issue records' {
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
            # Only fileA reports a warning, fileB is clean.
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $target = $ArgumentList[1]
                if ($target -eq $A) {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = ''
                        StdErr   = "$A(3,5) : Warning no-unused-params: Parameter ""x"" is declared but never used."
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmBicepLint -Context $C
        }
        $result.Status         | Should -Be 'pass'  # only warning, no error
        $result.Issues.Count   | Should -Be 1
        $result.Issues[0].File | Should -Be $a
        $result.Issues[0].Line | Should -Be 3
        $result.Issues[0].Column   | Should -Be 5
        $result.Issues[0].Severity | Should -Be 'warning'
        $result.Issues[0].Code     | Should -Be 'no-unused-params'
        $result.Issues[0].Message  | Should -Be 'Parameter "x" is declared but never used.'
    }

    It 'marks Status=fail when any diagnostic is Error severity' {
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
                $target = $ArgumentList[1]
                if ($target -eq $A) {
                    return [pscustomobject]@{
                        ExitCode = 1
                        StdOut   = ''
                        StdErr   = "$A(1,1) : Error BCP018: Expected the ""="" character at this location."
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmBicepLint -Context $C
        }
        $result.Status       | Should -Be 'fail'
        $result.Issues.Count | Should -Be 1
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].Code     | Should -Be 'BCP018'
    }

    It 'skips files inside dot-folders (e.g. .git)' {
        $hidden = Join-Path $script:moduleDir '.git'
        New-Item -ItemType Directory -Path $hidden -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $hidden 'should-be-skipped.bicep') -Value 'param z string' -Encoding utf8

        $ctx = $script:context
        $count = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            (Invoke-AvmBicepLint -Context $C).FilesProcessed
        }
        $count | Should -Be 2
    }
}
