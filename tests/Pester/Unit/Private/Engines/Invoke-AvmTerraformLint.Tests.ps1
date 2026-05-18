#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTerraformLint' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("tf-mod-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Value 'variable "x" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'variables.tf') -Value 'variable "y" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'README.md') -Value '# readme' -Encoding utf8

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
            Root      = $TestDrive
            Ecosystem = 'bicep'
            Source    = 'path-heuristic'
        }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $bicepCtx } {
                param($C)
                Invoke-AvmTerraformLint -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'invokes tflint once with --recursive --format=json and the module root as CWD' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'tflint'; Version = '0.55.1'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/tflint'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformLint -Context $C
        }
        $result.Engine         | Should -Be 'terraform'
        $result.Tool           | Should -Be 'tflint/0.55.1'
        $result.ToolPath       | Should -Be '/fake/tflint'
        $result.ToolSource     | Should -Be 'cache'
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 2

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/tflint' -and
                $ArgumentList.Count -eq 2 -and
                $ArgumentList[0] -eq '--recursive' -and
                $ArgumentList[1] -eq '--format=json'
            }
        }
    }

    It 'parses JSON issues into structured Issue records' {
        $ctx = $script:context
        $json = @'
{
  "issues": [
    {
      "rule": { "name": "terraform_unused_declarations", "severity": "warning" },
      "message": "variable \"y\" is declared but not used",
      "range": { "filename": "variables.tf", "start": { "line": 1, "column": 1 } }
    }
  ]
}
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'tflint'; Version = '0.55.1'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/tflint'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 2; StdOut = $J; StdErr = '' } }
            Invoke-AvmTerraformLint -Context $C
        }
        $result.Status         | Should -Be 'pass' # warnings only
        $result.Issues.Count   | Should -Be 1
        $result.Issues[0].Code | Should -Be 'terraform_unused_declarations'
        $result.Issues[0].Severity | Should -Be 'warning'
        $result.Issues[0].File | Should -Be 'variables.tf'
        $result.Issues[0].Line | Should -Be 1
    }

    It 'marks Status=fail when any issue has severity=error' {
        $ctx = $script:context
        $json = @'
{
  "issues": [
    {
      "rule": { "name": "terraform_typed_variables", "severity": "error" },
      "message": "boom",
      "range": { "filename": "main.tf", "start": { "line": 5, "column": 3 } }
    }
  ]
}
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'tflint'; Version = '0.55.1'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/tflint'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 2; StdOut = $J; StdErr = '' } }
            Invoke-AvmTerraformLint -Context $C
        }
        $result.Status            | Should -Be 'fail'
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].Line     | Should -Be 5
        $result.Issues[0].Column   | Should -Be 3
    }

    It 'throws AvmProcessException on unexpected tflint exit codes' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'tflint'; Version = '0.55.1'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/tflint'
                    }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'tflint blew up' } }
                Invoke-AvmTerraformLint -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'tflint blew up'
    }
}
