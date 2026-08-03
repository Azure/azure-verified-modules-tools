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

    It 'F40: reports skipped, not pass, and never shells out when there are no runnable examples' {
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
        $result.Status         | Should -Be 'skipped'
        $result.FilesProcessed | Should -Be 0
        $result.Issues         | Should -BeNullOrEmpty

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Times 0 -Exactly
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
                (-not ($ArgumentList -contains '-backend=false')) -and $StreamOutput
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'apply' -and ($ArgumentList -contains '-auto-approve') -and $StreamOutput
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'plan' -and ($ArgumentList -contains '-detailed-exitcode') -and $StreamOutput
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'destroy' -and ($ArgumentList -contains '-auto-approve') -and $StreamOutput
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
            Should -Invoke Invoke-AvmProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'plan' }
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
            Should -Invoke Invoke-AvmProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'apply' }
            Should -Invoke Invoke-AvmProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'destroy' }
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
            Should -Invoke Invoke-AvmProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'apply' }
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
            Should -Invoke Invoke-AvmProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'init' }
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
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*Refactor*'
            Should -Invoke Invoke-AvmProcess -Times 0 -Exactly
        }
    }

    It 'rejects a shell hook that has a PowerShell counterpart' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'pre.sh') -Value 'echo hi' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'pre.ps1') -Value 'exit 0' -Encoding utf8
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
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*pre.sh*'
            Should -Invoke Invoke-AvmProcess -Times 0 -Exactly
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

    It 'retries a transient capacity failure, destroying first, and reports it as a warning' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value '# example' -Encoding utf8
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; S = @{ Apply = 0 } } {
            param($C, $S)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                if ($ArgumentList[0] -eq 'apply') {
                    $S.Apply++
                    if ($S.Apply -eq 1) {
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Error: creating VM: SkuNotAvailable' }
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status             | Should -Be 'pass'
        $result.Issues.Count       | Should -Be 1
        $result.Issues[0].Severity | Should -Be 'warning'
        $result.Issues[0].Message  | Should -Match 'transient capacity error'
        $result.Issues[0].Message  | Should -Match 'retrying \(1 of 2\)'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter { $ArgumentList[0] -eq 'apply' }
            # one destroy to clear the failed attempt, one to tear the example down.
            Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter { $ArgumentList[0] -eq 'destroy' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'plan' }
        }
    }

    It 'does not retry an apply failure that is not a transient capacity error' {
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
                if ($ArgumentList[0] -eq 'apply') {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Error: OperationNotAllowed: cannot delete resource while nested resources exist' }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status             | Should -Be 'fail'
        $result.Issues.Count       | Should -Be 1
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].Message  | Should -Not -Match 'after \d+ retries'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'apply' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'destroy' }
        }
    }

    It 'fails after the retry budget is exhausted' {
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
                if ($ArgumentList[0] -eq 'apply') {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Error: AllocationFailed' }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status       | Should -Be 'fail'
        $result.Issues.Count | Should -Be 3
        ($result.Issues | Where-Object { $_.Severity -eq 'warning' }).Count | Should -Be 2
        ($result.Issues | Where-Object { $_.Severity -eq 'error' }).Message | Should -Match 'after 2 retries'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 3 -ParameterFilter { $ArgumentList[0] -eq 'apply' }
            Should -Invoke Invoke-AvmProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'plan' }
        }
    }

    It 'aborts the retry rather than redeploying when the retry destroy fails' {
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
                if ($ArgumentList[0] -eq 'apply') {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Error: Capacity Restrictions' }
                }
                if ($ArgumentList[0] -eq 'destroy') {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'destroy boom' }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status | Should -Be 'fail'
        ($result.Issues | Where-Object { $_.Message -match 'refusing to redeploy over partial state' }).Count | Should -Be 1

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'apply' }
        }
    }

    It 'skips retries entirely when MaxRetry is 0' {
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
                if ($ArgumentList[0] -eq 'apply') {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Error: SkuNotAvailable' }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTestE2e -Context $C -MaxRetry 0
        }
        $result.Status       | Should -Be 'fail'
        $result.Issues.Count | Should -Be 1

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'apply' }
        }
    }
}

Describe 'Test-AvmTerraformTransientError' {
    It 'classifies known capacity failures as retryable' {
        InModuleScope 'Avm.Authoring' {
            Test-AvmTerraformTransientError -Output 'Error: SkuNotAvailable'                              | Should -BeTrue
            Test-AvmTerraformTransientError -Output 'due to Capacity Restrictions in this region'         | Should -BeTrue
            Test-AvmTerraformTransientError -Output 'the size is currently not available in location uks' | Should -BeTrue
            Test-AvmTerraformTransientError -Output 'sku_selector found no deployable VM size'            | Should -BeTrue
            Test-AvmTerraformTransientError -Output 'AllocationFailed'                                    | Should -BeTrue
            Test-AvmTerraformTransientError -Output 'Allocation Failed'                                   | Should -BeTrue
            Test-AvmTerraformTransientError -Output 'results in exceeding approved quota'                 | Should -BeTrue
            Test-AvmTerraformTransientError -Output 'ERROR: skunotavailable'                              | Should -BeTrue
        }
    }

    It 'does not classify unrelated failures as retryable' {
        InModuleScope 'Avm.Authoring' {
            Test-AvmTerraformTransientError -Output ''                                                    | Should -BeFalse
            Test-AvmTerraformTransientError -Output '   '                                                 | Should -BeFalse
            Test-AvmTerraformTransientError -Output 'Error: Invalid value for variable'                   | Should -BeFalse
            # OperationNotAllowed also covers non-transient delete ordering, so it must not match.
            Test-AvmTerraformTransientError -Output 'OperationNotAllowed: cannot delete resource'         | Should -BeFalse
        }
    }

    It 'adds AVM_E2E_RETRY_PATTERN to the built-in list without replacing it' {
        InModuleScope 'Avm.Authoring' {
            try {
                $env:AVM_E2E_RETRY_PATTERN = 'ZonalAllocationFailure'
                Test-AvmTerraformTransientError -Output 'Error: ZonalAllocationFailure' | Should -BeTrue
                Test-AvmTerraformTransientError -Output 'Error: SkuNotAvailable'        | Should -BeTrue
                Test-AvmTerraformTransientError -Output 'Error: something else'         | Should -BeFalse
            }
            finally {
                Remove-Item Env:\AVM_E2E_RETRY_PATTERN -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Invoke-AvmTerraformTestE2e per-example targeting (F26/F27)' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("tf-tgt-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        foreach ($name in @('example-a', 'example-b', 'skipped')) {
            $dir = Join-Path $script:moduleDir 'examples' $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'main.tf') -Value '# example' -Encoding utf8
        }
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'skipped' '.e2eignore') -Value '' -Encoding utf8

        $script:context = [pscustomobject][ordered]@{
            Kind      = 'terraform-module-repo'
            Root      = $script:moduleDir
            Ecosystem = 'terraform'
            Source    = 'path-heuristic'
        }
    }

    It 'runs every runnable example when -Example is omitted' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/terraform' }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTestE2e -Context $C
        }
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 2
    }

    It 'runs only the named example when -Example is supplied' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/terraform' }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTestE2e -Context $C -Example 'example-b'
        }
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 1
    }

    It 'accepts a repo-relative example path' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/terraform' }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTestE2e -Context $C -Example 'examples/example-a'
        }
        $result.FilesProcessed | Should -Be 1
    }

    It 'hard-fails on an unknown example instead of passing with FilesProcessed=0' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool { throw 'should not resolve a tool' }
                Mock Invoke-AvmProcess { throw 'should not shell out' }
                Invoke-AvmTerraformTestE2e -Context $C -Example 'exampel-a'
            }
        }
        catch { $err = $_.Exception }

        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message        | Should -Match 'example-a, example-b'
    }

    It 'hard-fails when the named example carries .e2eignore' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool { throw 'should not resolve a tool' }
                Mock Invoke-AvmProcess { throw 'should not shell out' }
                Invoke-AvmTerraformTestE2e -Context $C -Example 'skipped'
            }
        }
        catch { $err = $_.Exception }

        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message        | Should -Match '\.e2eignore'
    }

    It 'emits a compact JSON array of runnable examples for -List without resolving a tool' {
        $ctx = $script:context
        $json = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool { throw 'should not resolve a tool' }
            Mock Invoke-AvmProcess { throw 'should not shell out' }
            Invoke-AvmTerraformTestE2e -Context $C -List
        }
        $json | Should -BeOfType ([string])
        $json | Should -Be '["example-a","example-b"]'
        (ConvertFrom-Json $json) | Should -Be @('example-a', 'example-b')
    }

    It 'emits [] for -List when there are no runnable examples' {
        $empty = Join-Path $TestDrive ("tf-empty-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $ctx = [pscustomobject]@{ Kind = 'terraform-module-repo'; Root = $empty; Ecosystem = 'terraform'; Source = 'path-heuristic' }
        $json = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool { throw 'should not resolve a tool' }
            Invoke-AvmTerraformTestE2e -Context $C -List
        }
        $json | Should -Be '[]'
    }

    It 'omits .e2eignore examples from -List' {
        $ctx = $script:context
        $json = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Invoke-AvmTerraformTestE2e -Context $C -List
        }
        # F47: the positive assertions are load-bearing. -List returning nothing
        # would satisfy the omission check on its own, and an empty discovery
        # surface silently collapses the CI matrix to zero e2e legs.
        $json | Should -Match 'example-a'
        (ConvertFrom-Json $json).Count | Should -BeGreaterThan 0
        $json | Should -Not -Match 'skipped'
    }

    It 'keeps -List output fromJson-clean under GITHUB_ACTIONS' {
        $ctx = $script:context
        $previous = $env:GITHUB_ACTIONS
        try {
            $env:GITHUB_ACTIONS = 'true'
            $json = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Invoke-AvmTerraformTestE2e -Context $C -List
            }
        }
        finally {
            $env:GITHUB_ACTIONS = $previous
        }
        # The workflow feeds this straight to fromJson() to build the e2e matrix,
        # so a single ::group:: marker leaking onto the same channel collapses
        # every e2e leg. Pin the whole string, not just its contents.
        $json | Should -Be '["example-a","example-b"]'
        $json | Should -Not -Match '::'
        (ConvertFrom-Json $json).Count | Should -Be 2
    }
}
