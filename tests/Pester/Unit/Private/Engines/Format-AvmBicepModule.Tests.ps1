#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Format-AvmBicepModule' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("bicep-mod-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null

        # Two .bicep files, one .bicepparam, one .md (should be skipped).
        $script:fileA = Join-Path $script:moduleDir 'main.bicep'
        $script:fileB = Join-Path $script:moduleDir 'nested.bicep'
        $script:fileC = Join-Path $script:moduleDir 'main.bicepparam'
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
        $bad = $tfCtx
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $bad } {
                param($C)
                Format-AvmBicepModule -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'invokes bicep format once per .bicep / .bicepparam file under the module root' {
        $ctx = $script:context
        $count = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            $r = Format-AvmBicepModule -Context $C
            $r.FilesProcessed
        }
        $count | Should -Be 3

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 3
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
            Format-AvmBicepModule -Context $C
        }
        $result.Engine     | Should -Be 'bicep'
        $result.Tool       | Should -Be 'bicep/0.30.3'
        $result.ToolPath   | Should -Be '/fake/bicep'
        $result.ToolSource | Should -Be 'cache'
    }

    It 'lists files whose content changed during formatting' {
        $ctx = $script:context
        $a = $script:fileA
        $b = $script:fileB

        $changed = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; A = $a; B = $b } {
            param($C, $A, $B)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            # Only rewrite fileA's content; leave fileB and the .bicepparam untouched.
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $target = $ArgumentList[1]
                if ($target -eq $A) {
                    Set-Content -LiteralPath $A -Value 'param x string = ''rewritten''' -Encoding utf8
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            $r = Format-AvmBicepModule -Context $C
            , $r.Changed
        }
        $changed.Count | Should -Be 1
        $changed[0]    | Should -Be $a
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
            (Format-AvmBicepModule -Context $C).FilesProcessed
        }
        $count | Should -Be 3
    }
    It 'reports a relative, forward-slashed Issue for drift without writing source files' {
        $ctx = $script:context
        $a = $script:fileA
        $c = $script:fileC
        $nestedDir = Join-Path $script:moduleDir 'nested'
        New-Item -ItemType Directory -Path $nestedDir | Out-Null
        $nested = Join-Path $nestedDir 'main.bicep'
        Set-Content -LiteralPath $nested -Value 'param z string' -Encoding utf8
        $beforeA = [System.IO.File]::ReadAllBytes($a)
        $beforeC = [System.IO.File]::ReadAllBytes($c)
        $beforeNested = [System.IO.File]::ReadAllBytes($nested)

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; N = $nested } {
            param($C, $N)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $content = if ($ArgumentList[1] -eq $N) {
                    "param z string = 'rewritten'`n"
                }
                else {
                    [System.IO.File]::ReadAllText($ArgumentList[1])
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = $content; StdErr = '' }
            }
            $r = Format-AvmBicepModule -Context $C -CheckDrift
            Should -Invoke Invoke-AvmProcess -Exactly 4 -ParameterFilter { $ArgumentList[-1] -eq '--stdout' }
            return $r
        }
        $result.Status | Should -Be 'fail'
        $result.Issues.Count | Should -Be 1
        $result.Changed | Should -Be @($nested)
        $result.Issues[0].File | Should -Be 'nested/main.bicep'
        $result.Issues[0].Code | Should -Be 'avm.bicep.fmt-drift'
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].Message | Should -Match 'avm format'
        [System.IO.File]::ReadAllBytes($a) | Should -Be $beforeA
        [System.IO.File]::ReadAllBytes($c) | Should -Be $beforeC
        [System.IO.File]::ReadAllBytes($nested) | Should -Be $beforeNested
    }

    It 'passes with no Issues in drift mode when every file is already formatted' {
        $ctx = $script:context
        $before = [System.IO.File]::ReadAllBytes($script:fileA)
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = [System.IO.File]::ReadAllText($ArgumentList[1])
                    StdErr = ''
                }
            }
            $r = Format-AvmBicepModule -Context $C -CheckDrift
            Should -Invoke Invoke-AvmProcess -Exactly 3 -ParameterFilter { $ArgumentList[-1] -eq '--stdout' }
            return $r
        }
        $result.Status | Should -Be 'pass'
        $result.Changed.Count | Should -Be 0
        $result.Issues.Count | Should -Be 0
        [System.IO.File]::ReadAllBytes($script:fileA) | Should -Be $before
    }

    It 'reports formatting drift in .bicepparam without changing the file' {
        $ctx = $script:context
        $paramFile = $script:fileC
        $before = [System.IO.File]::ReadAllBytes($paramFile)
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; ParamFile = $paramFile } {
            param($C, $ParamFile)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $content = if ($ArgumentList[1] -eq $ParamFile) {
                    "using './main.bicep'`nparam x = 'rewritten'`n"
                }
                else {
                    [System.IO.File]::ReadAllText($ArgumentList[1])
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = $content; StdErr = '' }
            }
            Format-AvmBicepModule -Context $C -CheckDrift
        }
        $result.Status | Should -Be 'fail'
        $result.Changed | Should -Be @($paramFile)
        $result.Issues[0].File | Should -Be 'main.bicepparam'
        [System.IO.File]::ReadAllBytes($paramFile) | Should -Be $before
    }

    It 'detects BOM-only drift while preserving the original bytes' {
        $ctx = $script:context
        $source = $script:fileA
        $content = [System.IO.File]::ReadAllText($source)
        [System.IO.File]::WriteAllText($source, $content, [System.Text.UTF8Encoding]::new($true))
        $before = [System.IO.File]::ReadAllBytes($source)

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = [System.IO.File]::ReadAllText($ArgumentList[1])
                    StdErr = ''
                }
            }
            Format-AvmBicepModule -Context $C -CheckDrift
        }
        $result.Status | Should -Be 'fail'
        $result.Changed | Should -Be @($source)
        [System.IO.File]::ReadAllBytes($source) | Should -Be $before
    }

    It 'propagates a formatter failure without changing any files' {
        $ctx = $script:context
        $source = $script:fileA
        $before = [System.IO.File]::ReadAllBytes($source)
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess {
                throw [AvmProcessException]::new('bicep format failed', '/fake/bicep', @('format'), 1, '', 'invalid file')
            }
            { Format-AvmBicepModule -Context $C -CheckDrift } |
                Should -Throw -ExceptionType ([AvmProcessException]) -ExpectedMessage '*bicep format failed*'
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[-1] -eq '--stdout' }
        }
        [System.IO.File]::ReadAllBytes($source) | Should -Be $before
    }

    It 'reports pass without Issues when files are rewritten outside drift mode' {
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
                if ($ArgumentList[1] -eq $A) {
                    Set-Content -LiteralPath $A -Value 'param x string = ''rewritten''' -Encoding utf8
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Format-AvmBicepModule -Context $C
        }
        $result.Status | Should -Be 'pass'
        $result.Issues.Count | Should -Be 0
        $result.Changed.Count | Should -Be 1
    }
}