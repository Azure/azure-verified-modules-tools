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

    It 'fails when the compiler exits nonzero without a parseable error diagnostic' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = 'pinned'; Source = 'cache'; Path = 'bicep'
                }
            }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 2; StdOut = ''; StdErr = 'Bicep could not read a module reference.'
                }
            }
            Invoke-AvmBicepTest -Context $C
        }

        $result.Status | Should -Be 'fail'
        $result.Issues.Count | Should -Be 2
        $result.Issues[0].Code | Should -Be 'avm.bicep.build-failed'
        $result.Issues[0].Message | Should -Match 'module reference'
    }

    It 'skips restoration offline and fails on an uncached external module' {
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            $previous = $env:AVM_OFFLINE
            try {
                $env:AVM_OFFLINE = '1'
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'bicep'; Version = 'pinned'; Source = 'cache'; Path = 'mock-bicep'
                    }
                }
                Mock Invoke-AvmProcess {
                    [pscustomobject]@{
                        ExitCode = 1; StdOut = ''; StdErr = 'External module is not cached.'
                    }
                }
                $result = Invoke-AvmBicepTest -Context $C
                $result.Status | Should -BeExactly 'fail'
                $result.Issues.Count | Should -Be 2
                $result.Issues[0].Code | Should -BeExactly 'avm.bicep.build-failed'
                $result.Issues[0].Message | Should -Match 'not cached'
                Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter {
                    $ArgumentList[0] -eq 'build' -and $ArgumentList -contains '--no-restore'
                }
            }
            finally {
                if ($null -eq $previous) {
                    Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
                }
                else {
                    $env:AVM_OFFLINE = $previous
                }
            }
        }
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

    It 'reports repeated compiler warnings once inline and in the result' {
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; A = $script:fileA } {
            param($C, $A)
            $script:events = [System.Collections.Generic.List[string]]::new()
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'pinned'; Source = 'cache'; Path = 'bicep' }
            }
            Mock Invoke-AvmProcess {
                $script:events.Add('build')
                [pscustomobject]@{
                    ExitCode = 0; StdOut = '{}'
                    StdErr = "$A(3,5) : Warning no-unused-params: Unused parameter.`n$A(4,5) : Warning no-unused-params: Unused parameter."
                }
            }
            Mock Write-AvmLog { $script:events.Add('warning') }

            $result = Invoke-AvmBicepTest -Context $C
            $result.Status | Should -Be 'pass'
            $result.Issues.Count | Should -Be 2
            @($script:events) | Should -Be @('build', 'warning', 'warning', 'build')
            Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter {
                $Level -eq 'Warning' -and $File -eq $A -and $Line -eq 3 -and $Column -eq 5
            }
            (ConvertTo-AvmResultLine -Result $result -Verb 'test') -join "`n" | Should -Match 'no-unused-params'
            (ConvertTo-AvmResultLine -Result $result -Verb 'test' -ExcludePresentedIssues) -join "`n" |
                Should -Not -Match 'no-unused-params'
        }
    }

    It 'anchors deduplicated warnings in GitHub Actions' {
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; A = $script:fileA } {
            param($C, $A)
            $savedActions = [System.Environment]::GetEnvironmentVariable('GITHUB_ACTIONS')
            $savedWorkspace = [System.Environment]::GetEnvironmentVariable('GITHUB_WORKSPACE')
            try {
                $env:GITHUB_ACTIONS = 'true'
                $env:GITHUB_WORKSPACE = $C.Root
                Mock Resolve-AvmTool {
                    [pscustomobject]@{ Name = 'bicep'; Version = 'pinned'; Source = 'cache'; Path = 'bicep' }
                }
                Mock Invoke-AvmProcess {
                    [pscustomobject]@{
                        ExitCode = 0; StdOut = '{}'
                        StdErr = "$A(3,5) : Warning no-unused-params: Unused parameter."
                    }
                }
                $output = @(Invoke-AvmBicepTest -Context $C 6>&1)
                $annotations = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                        ForEach-Object { [string]$_.MessageData })
                @($annotations).Count | Should -Be 1
                $annotations[0] | Should -BeExactly '::warning file=main.bicep,line=3,col=5::[no-unused-params] Unused parameter.'
            }
            finally {
                [System.Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $(if ($null -eq $savedActions) { [NullString]::Value } else { $savedActions }))
                [System.Environment]::SetEnvironmentVariable('GITHUB_WORKSPACE', $(if ($null -eq $savedWorkspace) { [NullString]::Value } else { $savedWorkspace }))
            }
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
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' } }
            Invoke-AvmBicepTest -Context $C
        }
        $result.Engine     | Should -Be 'bicep'
        $result.Tool       | Should -Be 'bicep/0.30.3'
        $result.ToolPath   | Should -Be '/fake/bicep'
        $result.ToolSource | Should -Be 'cache'
    }
}
