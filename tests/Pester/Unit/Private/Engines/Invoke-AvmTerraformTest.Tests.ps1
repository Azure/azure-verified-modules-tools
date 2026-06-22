#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTerraformTest' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("tf-mod-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Value 'variable "x" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'variables.tf') -Value 'variable "y" {}' -Encoding utf8

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
                Invoke-AvmTerraformTest -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'auto-inits then validates (when .terraform/ is absent) and returns Status=pass on a valid module' {
        $ctx = $script:context
        $okJson = '{ "format_version": "1.0", "valid": true, "error_count": 0, "warning_count": 0, "diagnostics": [] }'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $okJson } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                if ($ArgumentList[0] -eq 'init') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                if ($ArgumentList[0] -eq 'validate') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = $J; StdErr = '' }
                }
                throw "unexpected args: $($ArgumentList -join ' ')"
            }
            Invoke-AvmTerraformTest -Context $C
        }
        $result.Status         | Should -Be 'pass'
        $result.Engine         | Should -Be 'terraform'
        $result.Tool           | Should -Be 'terraform/1.15.3'
        $result.ToolPath       | Should -Be '/fake/terraform'
        $result.ToolSource     | Should -Be 'cache'
        $result.FilesProcessed | Should -Be 2
        $result.Issues         | Should -BeNullOrEmpty

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'init' -and $ArgumentList -contains '-backend=false'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'validate' -and $ArgumentList -contains '-json'
            }
        }
    }

    It 'skips init when .terraform/ already exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir '.terraform') -Force | Out-Null
        $ctx = $script:context
        $okJson = '{ "format_version": "1.0", "valid": true, "error_count": 0, "warning_count": 0, "diagnostics": [] }'
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $okJson } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $J; StdErr = '' } }
            $null = Invoke-AvmTerraformTest -Context $C

            Should -Invoke Invoke-AvmProcess -Exactly 1
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -eq 'init' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'validate' }
        }
    }

    It 'honours -NoInit and skips terraform init even when .terraform/ is absent' {
        $ctx = $script:context
        $okJson = '{ "format_version": "1.0", "valid": true, "error_count": 0, "warning_count": 0, "diagnostics": [] }'
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $okJson } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $J; StdErr = '' } }
            $null = Invoke-AvmTerraformTest -Context $C -NoInit

            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -eq 'init' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'validate' }
        }
    }

    It 'marks Status=fail when validate emits an error diagnostic' {
        $ctx = $script:context
        $errJson = @'
{
  "format_version": "1.0",
  "valid": false,
  "error_count": 1,
  "warning_count": 0,
  "diagnostics": [
    {
      "severity": "error",
      "summary": "Missing required argument",
      "detail": "The argument \"source\" is required",
      "range": { "filename": "main.tf", "start": { "line": 3, "column": 1 } }
    }
  ]
}
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $errJson } {
            param($C, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/terraform'
                }
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                [pscustomobject]@{ ExitCode = 1; StdOut = $J; StdErr = '' }
            }
            Invoke-AvmTerraformTest -Context $C
        }
        $result.Status            | Should -Be 'fail'
        $result.Issues.Count      | Should -Be 1
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].File     | Should -Be 'main.tf'
        $result.Issues[0].Line     | Should -Be 3
        $result.Issues[0].Message  | Should -Match 'required'
    }

    It 'throws AvmProcessException when terraform init itself fails' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/terraform'
                    }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'init boom' } }
                Invoke-AvmTerraformTest -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'init boom'
    }
}
