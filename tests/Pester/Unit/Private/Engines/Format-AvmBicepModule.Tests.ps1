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
}
