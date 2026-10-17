#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: MAPOTF native Terraform test migration' -Tag Qualification {
BeforeAll {
        $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring'
        Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $script:mapotf = InModuleScope Avm.Authoring { (Resolve-AvmTool -Name mapotf).Path }
        $script:terraform = InModuleScope Avm.Authoring { (Resolve-AvmTool -Name terraform).Path }
        $script:options = [pscustomobject]@{
            ToolPath      = $script:mapotf
            TerraformPath = $script:terraform
            ProfileDirs = @{
                module              = Join-Path $moduleRoot 'Resources' 'mapotf' 'module'
                'unit-test-inspect' = Join-Path $moduleRoot 'Resources' 'mapotf' 'unit-test-inspect'
                'unit-test'         = Join-Path $moduleRoot 'Resources' 'mapotf' 'unit-test'
            }
            EnvVars     = @{}
            InspectionRoot = Join-Path $TestDrive 'provider-inspection'
        }
        $script:utf8 = [System.Text.UTF8Encoding]::new($false)

        function New-NativeTestFixture {
            param([string] $GlobalLocation, [string] $RunLocation)

            $root = Join-Path $TestDrive (([guid]::NewGuid().ToString('N')) + ' spaces, equals=value')
            $child = Join-Path $root 'modules' 'child'
            $unit = Join-Path $root 'tests' 'unit'
            $null = New-Item -ItemType Directory -Path $child, $unit -Force
            foreach ($target in @($root, $child)) {
                [System.IO.File]::WriteAllText((Join-Path $target 'main.tf'), @'
variable "enable_telemetry" {
  type    = bool
  default = true
}
variable "hub_regions" {
  type = map(string)
}
variable "mptf" {
  type = map(string)
}
locals {
  primary_region = var.hub_regions.primary
}
'@, $script:utf8)
            }
            $source = @'
# Preserve the authored regions and expressions.
mock_provider "azapi" {}
mock_provider "azapi" {
  alias = "alternate"
  mock_data "azapi_client_config" {
    defaults = {
      subscription_resource_id = "/subscriptions/11111111-1111-1111-1111-111111111111"
    }
  }
}
variables {
__GLOBAL_LOCATION__  enable_telemetry = false
  hub_regions = {
    primary   = "westeurope"
    secondary = "swedencentral"
  }
  mptf = {
    location = "not-a-global-location"
  }
}
run "root" {
  command = plan
__RUN_LOCATION__
  assert {
    condition     = local.primary_region == "westeurope"
    error_message = "Keep the authored { region }."
  }
}
run "child" {
  command = plan
  module {
    source = "./modules/child"
  }
  assert {
    condition     = var.hub_regions.secondary == "swedencentral"
    error_message = "Keep the delegated target and its inputs."
  }
}
'@
            $global = if ($PSBoundParameters.ContainsKey('GlobalLocation')) { "  location = $GlobalLocation`n" } else { '' }
            $run = if ($PSBoundParameters.ContainsKey('RunLocation')) {
                "  variables {`n    location = $RunLocation`n    enable_telemetry = false`n  }"
            }
            else { '' }
            $source = $source.Replace('__GLOBAL_LOCATION__', $global).Replace('__RUN_LOCATION__', $run) + "`n"
            $test = Join-Path $unit 'scopes.tftest.hcl'
            [System.IO.File]::WriteAllText($test, $source, $script:utf8)
            [System.IO.File]::WriteAllText((Join-Path $unit 'untouched.tftest.hcl'), $source, $script:utf8)
            $targets = @(
                [pscustomobject]@{ Path = $root; Scope = 'root'; Profiles = @('root', 'module', 'common') }
                [pscustomobject]@{ Path = $child; Scope = 'module'; Profiles = @('root', 'module', 'common') }
            )
            [pscustomobject]@{
                Root    = $root
                Child   = $child
                Test    = $test
                Targets = $targets
                Scope   = [pscustomobject]@{
                    File         = Get-Item -LiteralPath $test
                    Owner        = $targets[0]
                    RelativePath = 'tests/unit/scopes.tftest.hcl'
                    IsUnitTest   = $true
                }
            }
        }

        function Read-NativeTestFixture {
            param($Fixture)
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $Fixture; Options = $script:options } {
                param($Fixture, $Options)
                Get-AvmTerraformUnitTestInspection -Scope $Fixture.Scope -ModuleTargets $Fixture.Targets -Options $Options
            }
        }

        function Invoke-NativeLocationProfile {
            param($Fixture, [string[]] $Locations = @(), [string] $ResourceId)
            InModuleScope Avm.Authoring -Parameters @{
                Fixture   = $Fixture
                Options   = $script:options
                Locations = $Locations
                ResourceId = $ResourceId
            } {
                param($Fixture, $Options, $Locations, $ResourceId)
                $encoded = ConvertTo-Json -InputObject @($Locations) -Compress
                $arguments = @(
                    'transform', '--tf-dir', $Fixture.Root, '--test-file', $Fixture.Scope.RelativePath,
                    '--mptf-dir', $Options.ProfileDirs['unit-test'],
                    '--mptf-var', "new_location_modules=$encoded"
                )
                if ($ResourceId) {
                    $arguments += @('--mptf-var', ('telemetry_subscription_resource_ids=' +
                        (ConvertTo-Json -InputObject @{ azapi = $ResourceId } -Compress)))
                }
                $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList $arguments -WorkingDirectory $Fixture.Root
                $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
                    'clean-backup', '--tf-dir', $Fixture.Root, '--test-file', $Fixture.Scope.RelativePath
                ) -WorkingDirectory $Fixture.Root
            }
        }
    }

AfterAll {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

It 'adds only new run inputs, preserves other files and is stable on the second pass' {
        $fixture = New-NativeTestFixture
        $before = Read-NativeTestFixture -Fixture $fixture
        foreach ($target in @($fixture.Root, $fixture.Child)) {
            [System.IO.File]::WriteAllText((Join-Path $target 'location.tf'), "variable `"location`" {`n  type = string`n}`n", $script:utf8)
        }
        $afterSource = Read-NativeTestFixture -Fixture $fixture
        $newLocations = @($afterSource.modules.Keys | Where-Object {
                -not $before.modules[$_].variables.ContainsKey('location') -and
                $afterSource.modules[$_].variables.location.required
            })
        $newLocations | Should -HaveCount 2
        $untouched = Join-Path $fixture.Root 'tests' 'unit' 'untouched.tftest.hcl'
        $otherHash = (Get-FileHash -LiteralPath $untouched).Hash
        $sourceHash = (Get-FileHash -LiteralPath (Join-Path $fixture.Root 'main.tf')).Hash
        Invoke-NativeLocationProfile -Fixture $fixture -Locations $newLocations
        $after = Read-NativeTestFixture -Fixture $fixture
        foreach ($name in @('root', 'child')) {
            $after.test.runs[$name].variables[0].mptf.attributes.location | Should -BeExactly 'eastus'
            $after.test.runs[$name].assert[0].mptf.attributes.condition |
                Should -BeExactly $before.test.runs[$name].assert[0].mptf.attributes.condition
        }
        $after.test.variables.mptf.attributes.enable_telemetry | Should -BeFalse
        $after.test.variables.mptf.attributes.hub_regions.primary | Should -BeExactly 'westeurope'
        $after.test.variables.mptf.attributes.hub_regions.secondary | Should -BeExactly 'swedencentral'
        $after.test.variables.mptf.attributes.mptf.location | Should -BeExactly 'not-a-global-location'
        $after.test.run_modules.child.source | Should -BeExactly './modules/child'
        (Get-FileHash -LiteralPath $untouched).Hash | Should -BeExactly $otherHash
        (Get-FileHash -LiteralPath (Join-Path $fixture.Root 'main.tf')).Hash | Should -BeExactly $sourceHash
        $first = [System.IO.File]::ReadAllText($fixture.Test)
        Invoke-NativeLocationProfile -Fixture $fixture -Locations $newLocations
        [System.IO.File]::ReadAllText($fixture.Test) | Should -BeExactly $first
        @(Get-ChildItem -LiteralPath $fixture.Root -Recurse -Filter '*.mptfbackup') | Should -HaveCount 0
    }

It 'repairs a comment-only AzAPI mock without dropping its comment' {
        $fixture = New-NativeTestFixture
        $source = @'
mock_provider "azapi" {
  # Keep the authored provider explanation.
}
run "root" { command = plan }
'@
        [System.IO.File]::WriteAllText($fixture.Test, $source, $script:utf8)
        $before = Read-NativeTestFixture -Fixture $fixture
        $resourceId = InModuleScope Avm.Authoring -Parameters @{ Test = $before.test; Path = $fixture.Test } {
            param($Test, $Path)
            Get-AvmTerraformTelemetryMockResourceId -Test $Test -Path $Path
        }
        $resourceId | Should -BeExactly '/subscriptions/00000000-0000-0000-0000-000000000000'
        Invoke-NativeLocationProfile -Fixture $fixture -ResourceId $resourceId
        $after = Read-NativeTestFixture -Fixture $fixture
        $after.test.mock_providers.azapi.mock_data[0].mptf.attributes.defaults.subscription_resource_id |
            Should -BeExactly $resourceId
        [System.IO.File]::ReadAllText($fixture.Test) |
            Should -Match '# Keep the authored provider explanation\.'
        $first = [System.IO.File]::ReadAllText($fixture.Test)
        Invoke-NativeLocationProfile -Fixture $fixture -ResourceId $resourceId
        [System.IO.File]::ReadAllText($fixture.Test) | Should -BeExactly $first
        @(Get-ChildItem -LiteralPath $fixture.Root -Recurse -Filter '*.mptfbackup') | Should -HaveCount 0
    }
}
