#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: Terraform deprecated interfaces' -Tag 'Integration' -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $script:OriginalAvmHome = $env:AVM_HOME
        $script:OriginalPluginCache = $env:TF_PLUGIN_CACHE_DIR
        if (-not $env:AVM_HOME) {
            $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        }
        if (-not $env:TF_PLUGIN_CACHE_DIR) {
            $env:TF_PLUGIN_CACHE_DIR = Join-Path $TestDrive 'provider-cache'
        }
        $null = New-Item -ItemType Directory -Path $env:TF_PLUGIN_CACHE_DIR -Force
        Import-Module (Join-Path $script:RepoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
        Install-AvmTool -Name terraform -SkipModuleVersionCheck -InformationAction Continue -ErrorAction Stop

        function New-AvmDeprecationFixture {
            param([Parameter(Mandatory)] [string] $Root)

            $null = New-Item -ItemType Directory -Path $Root -Force
            [IO.File]::WriteAllText((Join-Path $Root 'terraform.tf'), @'
terraform {
  required_version = ">= 1.15.0, < 2.0.0"
}
'@ + "`n")
            [IO.File]::WriteAllText((Join-Path $Root 'main.tf'), @'
variable "current_value" {
  type    = string
  default = "current"
}

variable "legacy_value" {
  type       = string
  default    = null
  deprecated = "Use the current_value input instead."
}

locals {
  value = coalesce(var.legacy_value, var.current_value)
}

output "current_value" {
  value = local.value
}

output "legacy_value" {
  value      = local.value
  deprecated = "Use the current_value output instead."
}
'@ + "`n")

            foreach ($example in @('default', 'ignored')) {
                $exampleRoot = Join-Path $Root 'examples' $example
                $null = New-Item -ItemType Directory -Path $exampleRoot -Force
                [IO.File]::WriteAllText((Join-Path $exampleRoot 'main.tf'), @'
module "test" {
  source       = "../.."
  legacy_value = "compatibility"
}

output "legacy_value" {
  value = module.test.legacy_value
}
'@ + "`n")
            }
            [IO.File]::WriteAllText((Join-Path $Root 'examples' 'ignored' '.e2eignore'), '')
        }
    }

    AfterAll {
        $env:AVM_HOME = $script:OriginalAvmHome
        $env:TF_PLUGIN_CACHE_DIR = $script:OriginalPluginCache
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    Context 'provider-free native regressions' {
        BeforeEach {
            $script:Library = Join-Path $TestDrive ('library-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-AvmDeprecationFixture -Root $script:Library
        }

        It 'proves deprecated outputs are invalid when a library is validated as a root' {
            $native = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $script:Library } {
                param($Root)
                $tool = Resolve-AvmTool -Name terraform
                Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @('validate', '-json', '-no-color') `
                    -WorkingDirectory $Root -IgnoreExitCode
            }

            $native.ExitCode | Should -Be 1 -Because $native.StdErr
            $payload = $native.StdOut | ConvertFrom-Json
            $payload.valid | Should -BeFalse
            @($payload.diagnostics | Where-Object {
                    $_.severity -eq 'error' -and
                    "$($_.summary) $($_.detail)" -match 'deprecat' -and
                    "$($_.summary) $($_.detail)" -match 'root module'
                }).Count | Should -BeGreaterThan 0
        }

        It 'validates ordinary and e2e-ignored examples with both deprecation warnings' {
            $result = Invoke-AvmTest -Path $script:Library -Ecosystem terraform

            $result.Status | Should -Be 'pass' -Because ($result.Issues | ConvertTo-Json -Depth 4 -Compress)
            $result.FilesProcessed | Should -Be 2
            @($result.Issues | Where-Object Severity -eq 'error').Count | Should -Be 0
            @($result.Issues | Where-Object {
                    $_.Code -in @('terraform.module-coverage', 'terraform.module-coverage-unavailable')
                }).Count | Should -Be 0 -Because 'the real module named test reaches the checkout root'
            foreach ($example in @('default', 'ignored')) {
                $warnings = @($result.Issues | Where-Object {
                        $_.Severity -eq 'warning' -and $_.File -eq "examples/$example/main.tf"
                    })
                @($warnings | Where-Object Message -Match 'Use the current_value input instead').Count |
                    Should -BeGreaterThan 0
                @($warnings | Where-Object Message -Match 'Use the current_value output instead').Count |
                    Should -BeGreaterThan 0
                @($warnings | Where-Object { $_.Line -le 0 }).Count | Should -Be 0
            }
        }

        It 'still fails on an actual validation error in a deprecated library' {
            [IO.File]::AppendAllText((Join-Path $script:Library 'main.tf'), @'

output "broken" {
  value = var.undeclared
}
'@ + "`n")

            $result = Invoke-AvmTest -Path $script:Library -Ecosystem terraform

            $result.Status | Should -Be 'fail'
            @($result.Issues | Where-Object {
                    $_.Severity -eq 'error' -and $_.File -eq 'main.tf' -and
                    $_.Message -match 'undeclared input variable'
                }).Count | Should -BeGreaterThan 0
        }

        It 'warns without validating unreached deprecated root modules and shipped submodules' {
            $unused = Join-Path $script:Library 'modules' 'unused'
            $null = New-Item -ItemType Directory -Path $unused -Force
            [IO.File]::WriteAllText((Join-Path $unused 'main.tf'), @'
output "legacy_value" {
  value      = "unused"
  deprecated = "This unused library output is deprecated."
}
'@ + "`n")
            foreach ($example in @('default', 'ignored')) {
                [IO.File]::WriteAllText((Join-Path $script:Library 'examples' $example 'main.tf'), @'
output "independent_value" {
  value = "independent example"
}
'@ + "`n")
            }

            $result = Invoke-AvmTest -Path $script:Library -Ecosystem terraform

            $result.Status | Should -Be 'pass' -Because ($result.Issues | ConvertTo-Json -Depth 4 -Compress)
            @($result.Issues | Where-Object Severity -eq 'error').Count | Should -Be 0
            foreach ($moduleFile in @('main.tf', 'modules/unused/main.tf')) {
                @($result.Issues | Where-Object {
                        $_.Severity -eq 'warning' -and $_.File -eq $moduleFile -and
                        $_.Message -match 'example.*coverage'
                    }).Count | Should -BeGreaterThan 0
            }
        }

        It 'runs plan-only native unit tests through a wrapper launched from the library root' {
            $testDirectory = Join-Path $script:Library 'tests' 'unit'
            $null = New-Item -ItemType Directory -Path $testDirectory -Force
            [IO.File]::WriteAllText((Join-Path $testDirectory 'compatibility.tftest.hcl'), @'
run "compatibility" {
  command = plan

  module {
    source = "./examples/default"
  }

  assert {
    condition     = output.legacy_value == "compatibility"
    error_message = "The wrapper must preserve the deprecated input and output."
  }
}
'@ + "`n")

            $result = Invoke-AvmTestUnit -Path $script:Library -Ecosystem terraform

            $result.Status | Should -Be 'pass' -Because ($result.Issues | ConvertTo-Json -Depth 4 -Compress)
            $result.RunsTotal | Should -Be 1
            $result.RunsFailed | Should -Be 0
        }

        It 'rejects a plan-only native test that selects the library without a wrapper' {
            $testDirectory = Join-Path $script:Library 'tests' 'unit'
            $null = New-Item -ItemType Directory -Path $testDirectory -Force
            [IO.File]::WriteAllText((Join-Path $testDirectory 'direct.tftest.hcl'), @'
run "direct" {
  command = plan

  module {
    source = "./"
  }
}
'@ + "`n")

            $result = Invoke-AvmTestUnit -Path $script:Library -Ecosystem terraform

            $result.Status | Should -Be 'fail'
            @($result.Issues | Where-Object {
                    $_.Severity -eq 'error' -and $_.Message -match 'deprecat' -and
                    $_.Message -match 'root module'
                }).Count | Should -BeGreaterThan 0
        }
    }

    It 'statically validates the existing AzAPI mock fixture and preserves native warnings' {
        $fixture = Join-Path $TestDrive 'terraform-azure-avm-res-mock'
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'tests' 'fixtures' 'modules' 'terraform-azure-avm-res-mock') `
            -Destination $fixture -Recurse -Force

        $result = Invoke-AvmTest -Path $fixture -Ecosystem terraform

        $result.Status | Should -Be 'pass' -Because ($result.Issues | ConvertTo-Json -Depth 4 -Compress)
        $result.FilesProcessed | Should -Be 7
        @($result.Issues | Where-Object Severity -eq 'error').Count | Should -Be 0
        @($result.Issues | Where-Object {
                $_.Code -in @('terraform.module-coverage', 'terraform.module-coverage-unavailable')
            }).Count | Should -Be 0 -Because 'the examples reach the local checkout root despite its deprecated interfaces'
        $warnings = @($result.Issues | Where-Object {
                $_.Severity -eq 'warning' -and $_.File -eq 'examples/default/main.tf'
            })
        @($warnings | Where-Object Message -Match 'Use the create_mock_resources input instead').Count |
            Should -BeGreaterThan 0
        @($warnings | Where-Object Message -Match 'Use the example_resource_ids output instead').Count |
            Should -BeGreaterThan 0
    }
}
