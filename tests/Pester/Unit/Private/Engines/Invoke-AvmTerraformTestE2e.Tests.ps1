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

    It 'runs the pre.ps1 hook before terraform and the post.ps1 hook after' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'pre.ps1') -Value 'exit 0' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'post.ps1') -Value 'exit 0' -Encoding utf8
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
        $result.Issues         | Should -BeNullOrEmpty

        InModuleScope 'Avm.Authoring' {
            # Hooks run as 'pwsh ... -File <hook>' subprocesses, one each.
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                ($ArgumentList -contains '-File') -and (($ArgumentList -join ' ') -like '*pre.ps1')
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                ($ArgumentList -contains '-File') -and (($ArgumentList -join ' ') -like '*post.ps1')
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'init' }
        }
    }

    It 'still runs the post.ps1 hook after a terraform init failure' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'post.ps1') -Value 'exit 0' -Encoding utf8
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
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status            | Should -Be 'fail'
        $result.Issues.Count      | Should -Be 1
        $result.Issues[0].Message | Should -Match 'init'

        InModuleScope 'Avm.Authoring' {
            # post.ps1 always runs, even though init failed.
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                ($ArgumentList -contains '-File') -and (($ArgumentList -join ' ') -like '*post.ps1')
            }
            Should -Invoke Invoke-AvmProcess -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'apply' }
        }
    }

    It 'skips terraform when the pre.ps1 hook fails but still runs post.ps1' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'pre.ps1') -Value 'exit 3' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'post.ps1') -Value 'exit 0' -Encoding utf8
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
                if (($ArgumentList -join ' ') -like '*pre.ps1')  { return [pscustomobject]@{ ExitCode = 3; StdOut = ''; StdErr = 'pre boom' } }
                if (($ArgumentList -join ' ') -like '*post.ps1') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                throw "terraform must not run after a failed pre-hook: $($ArgumentList[0])"
            }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status            | Should -Be 'fail'
        $result.Issues.Count      | Should -Be 1
        $result.Issues[0].File    | Should -Be 'examples/default/pre.ps1'
        $result.Issues[0].Message | Should -Match 'pre\.ps1 hook failed'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'init' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                ($ArgumentList -contains '-File') -and (($ArgumentList -join ' ') -like '*post.ps1')
            }
        }
    }

    It 'records an Issue when the post.ps1 hook exits non-zero' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'post.ps1') -Value 'exit 4' -Encoding utf8
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
                if (($ArgumentList -join ' ') -like '*post.ps1') { return [pscustomobject]@{ ExitCode = 4; StdOut = ''; StdErr = 'post boom' } }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status            | Should -Be 'fail'
        $result.Issues.Count      | Should -Be 1
        $result.Issues[0].File    | Should -Be 'examples/default/post.ps1'
        $result.Issues[0].Message | Should -Match 'post\.ps1 hook failed'
    }

    It 'throws a configuration error when a shell hook is present' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'pre.sh') -Value 'echo hi' -Encoding utf8
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess { throw 'should not shell out when a .sh hook is rejected' }
            { Invoke-AvmTerraformTestE2e -Context $C } |
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*convert these shell hooks*'
            Should -Invoke Invoke-AvmProcess -Times 0
        }
    }

    It 'parses a .env file and passes its values to every terraform step via -EnvVars' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' '.env') -Value @(
            '# secrets written by pre.ps1'
            'ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000'
            'export TF_VAR_name="quoted value"'
        ) -Encoding utf8
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
        $result.Status | Should -Be 'pass'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'init' -and
                $EnvVars['ARM_SUBSCRIPTION_ID'] -eq '00000000-0000-0000-0000-000000000000' -and
                $EnvVars['TF_VAR_name'] -eq 'quoted value'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'apply' -and
                $EnvVars['ARM_SUBSCRIPTION_ID'] -eq '00000000-0000-0000-0000-000000000000' -and
                $EnvVars['TF_VAR_name'] -eq 'quoted value'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'plan' -and
                $EnvVars['ARM_SUBSCRIPTION_ID'] -eq '00000000-0000-0000-0000-000000000000' -and
                $EnvVars['TF_VAR_name'] -eq 'quoted value'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'destroy' -and
                $EnvVars['ARM_SUBSCRIPTION_ID'] -eq '00000000-0000-0000-0000-000000000000' -and
                $EnvVars['TF_VAR_name'] -eq 'quoted value'
            }
        }
    }
}
