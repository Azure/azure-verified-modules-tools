#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTerraformTestE2e' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("tf-e2e-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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
            Kind = 'bicep-module'; Root = $TestDrive; Ecosystem = 'bicep'; Source = 'path-heuristic'
        }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $bicepCtx } {
                param($C)
                Invoke-AvmTerraformTestE2e -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'returns a clean pass with FilesProcessed=0 and never shells out when there are no runnable examples' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess { throw 'should not shell out' }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 0
        $result.Issues         | Should -BeNullOrEmpty

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Times 0
        }
    }

    It 'runs init/apply/plan/destroy for one example and returns pass with the expected argv' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
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
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status         | Should -Be 'pass'
        $result.Engine         | Should -Be 'terraform'
        $result.Tool           | Should -Be 'terraform/1.15.3'
        $result.ToolPath       | Should -Be '/fake/terraform'
        $result.ToolSource     | Should -Be 'cache'
        $result.FilesProcessed | Should -Be 1
        $result.Issues         | Should -BeNullOrEmpty

        InModuleScope 'Avm.Authoring' {
            # Real backend init: -input=false but NOT -backend=false.
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'init' -and ($ArgumentList -contains '-input=false') -and
                (-not ($ArgumentList -contains '-backend=false'))
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'apply' -and ($ArgumentList -contains '-auto-approve')
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'plan' -and ($ArgumentList -contains '-detailed-exitcode')
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'destroy' -and ($ArgumentList -contains '-auto-approve')
            }
        }
    }

    It 'skips example directories carrying a .e2eignore marker' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'keep') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'keep' 'main.tf') -Value '# keep' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'skip') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'skip' 'main.tf') -Value '# skip' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'skip' '.e2eignore') -Value '' -Encoding utf8
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
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 1

        InModuleScope 'Avm.Authoring' {
            # Exactly one example processed => one init.
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'init' }
        }
    }

    It 'records an idempotency failure when the second plan reports changes (exit 2) but still destroys' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
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
                if ($ArgumentList[0] -eq 'plan') { return [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = '' } }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status            | Should -Be 'fail'
        $result.FilesProcessed    | Should -Be 1
        $result.Issues.Count      | Should -Be 1
        $result.Issues[0].File    | Should -Be 'examples/default'
        $result.Issues[0].Message | Should -Match 'idempotency'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'destroy' }
        }
    }

    It 'skips the idempotency plan when apply fails but still destroys' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
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
                if ($ArgumentList[0] -eq 'apply') { return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'apply boom' } }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status            | Should -Be 'fail'
        $result.Issues.Count      | Should -Be 1
        $result.Issues[0].Message | Should -Match 'apply'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'plan' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'destroy' }
        }
    }

    It 'records an init failure and runs nothing else for that example' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
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
                if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'init boom' } }
                throw "should not run $($ArgumentList[0]) after a failed init"
            }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status            | Should -Be 'fail'
        $result.Issues.Count      | Should -Be 1
        $result.Issues[0].Message | Should -Match 'init'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'apply' }
            Should -Invoke Invoke-AvmProcess -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'destroy' }
        }
    }

    It 'marks Status=fail when destroy fails' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
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
                if ($ArgumentList[0] -eq 'destroy') { return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'destroy boom' } }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status            | Should -Be 'fail'
        $result.Issues.Count      | Should -Be 1
        $result.Issues[0].Message | Should -Match 'destroy'
    }
}
