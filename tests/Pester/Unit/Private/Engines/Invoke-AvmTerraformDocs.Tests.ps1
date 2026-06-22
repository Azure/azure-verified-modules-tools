#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTerraformDocs' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("tf-mod-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Value 'variable "x" {}' -Encoding utf8
        $script:readme = Join-Path $script:moduleDir 'README.md'
        Set-Content -LiteralPath $script:readme -Value "# my-module`n`n<!-- BEGIN_TF_DOCS -->`n<!-- END_TF_DOCS -->`n" -Encoding utf8

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
                Invoke-AvmTerraformDocs -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'invokes terraform-docs in inject mode and reports README as changed when it mutates' {
        $ctx = $script:context
        $readme = $script:readme
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $readme } {
            param($C, $R)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform-docs'; Version = '0.20.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform-docs'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList, $WorkingDirectory)
                Add-Content -LiteralPath $R -Value "`n| name | description |`n|------|-------------|`n| x | something |`n"
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformDocs -Context $C
        }
        $result.Status         | Should -Be 'pass'
        $result.Engine         | Should -Be 'terraform'
        $result.Tool           | Should -Be 'terraform-docs/0.20.0'
        $result.FilesProcessed | Should -Be 1
        $result.Changed        | Should -Be @('README.md')

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'markdown' -and `
                    $ArgumentList[1] -eq 'table' -and `
                    $ArgumentList -contains '--output-file' -and `
                    $ArgumentList -contains '--output-mode' -and `
                    $ArgumentList -contains 'inject'
            }
        }
    }

    It 'reports an empty Changed array when terraform-docs leaves README untouched' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform-docs'; Version = '0.20.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform-docs'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformDocs -Context $C
        }
        $result.Status  | Should -Be 'pass'
        $result.Changed | Should -BeNullOrEmpty
    }

    It 'throws AvmProcessException when terraform-docs exits non-zero' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'terraform-docs'; Version = '0.20.0'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/terraform-docs'
                    }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'no inject markers' } }
                Invoke-AvmTerraformDocs -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'no inject markers'
    }

    It 'honours a root .terraform-docs.yml via --config instead of the table fallback' {
        Set-Content -LiteralPath (Join-Path $script:moduleDir '.terraform-docs.yml') `
            -Value 'formatter: "markdown document"' -Encoding utf8
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform-docs'; Version = '0.20.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform-docs'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformDocs -Context $C
        }
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 1

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq '--config' -and `
                    $ArgumentList[1] -eq '.terraform-docs.yml' -and `
                    $ArgumentList[-1] -eq '.' -and `
                    ($ArgumentList -notcontains 'markdown')
            }
        }
    }

    It 'documents the root and each example when examples carry a shared config' {
        Set-Content -LiteralPath (Join-Path $script:moduleDir '.terraform-docs.yml') `
            -Value 'formatter: "markdown document"' -Encoding utf8
        $examplesDir = Join-Path $script:moduleDir 'examples'
        New-Item -ItemType Directory -Path $examplesDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $examplesDir '.terraform-docs.yml') `
            -Value 'formatter: "markdown document"' -Encoding utf8
        $defaultDir = Join-Path $examplesDir 'default'
        New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $defaultDir 'main.tf') -Value 'variable "y" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $defaultDir 'README.md') `
            -Value "<!-- BEGIN_TF_DOCS -->`n<!-- END_TF_DOCS -->`n" -Encoding utf8

        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform-docs'; Version = '0.20.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform-docs'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformDocs -Context $C
        }
        $result.FilesProcessed | Should -Be 2

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 2
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq '--config' -and $ArgumentList[-1] -match 'default$'
            }
        }
    }

    It 'does not walk examples when examples has no .terraform-docs.yml' {
        Set-Content -LiteralPath (Join-Path $script:moduleDir '.terraform-docs.yml') `
            -Value 'formatter: "markdown document"' -Encoding utf8
        $defaultDir = Join-Path $script:moduleDir 'examples' 'default'
        New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $defaultDir 'main.tf') -Value 'variable "y" {}' -Encoding utf8

        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform-docs'; Version = '0.20.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform-docs'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformDocs -Context $C
        }
        $result.FilesProcessed | Should -Be 1
    }

    It 'skips an example subdirectory that has no .tf files' {
        Set-Content -LiteralPath (Join-Path $script:moduleDir '.terraform-docs.yml') `
            -Value 'formatter: "markdown document"' -Encoding utf8
        $examplesDir = Join-Path $script:moduleDir 'examples'
        New-Item -ItemType Directory -Path $examplesDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $examplesDir '.terraform-docs.yml') `
            -Value 'formatter: "markdown document"' -Encoding utf8
        $emptyDir = Join-Path $examplesDir 'empty'
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $emptyDir 'README.md') -Value 'no tf here' -Encoding utf8
        $realDir = Join-Path $examplesDir 'real'
        New-Item -ItemType Directory -Path $realDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $realDir 'main.tf') -Value 'variable "z" {}' -Encoding utf8

        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform-docs'; Version = '0.20.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform-docs'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformDocs -Context $C
        }
        $result.FilesProcessed | Should -Be 2

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter {
                $ArgumentList[-1] -match 'empty$'
            }
        }
    }

    It 'documents submodules when modules carry a shared config' {
        Set-Content -LiteralPath (Join-Path $script:moduleDir '.terraform-docs.yml') `
            -Value 'formatter: "markdown document"' -Encoding utf8
        $modulesDir = Join-Path $script:moduleDir 'modules'
        New-Item -ItemType Directory -Path $modulesDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $modulesDir '.terraform-docs.yml') `
            -Value 'formatter: "markdown document"' -Encoding utf8
        $subDir = Join-Path $modulesDir 'subnet'
        New-Item -ItemType Directory -Path $subDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $subDir 'main.tf') -Value 'variable "s" {}' -Encoding utf8

        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform-docs'; Version = '0.20.0'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform-docs'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformDocs -Context $C
        }
        $result.FilesProcessed | Should -Be 2

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq '--config' -and $ArgumentList[-1] -match 'subnet$'
            }
        }
    }
}
