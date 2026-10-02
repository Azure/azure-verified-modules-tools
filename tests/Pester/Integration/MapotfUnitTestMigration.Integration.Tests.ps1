#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: MAPOTF native Terraform test migration' -Tag 'Integration' -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
        Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $script:mapotf = InModuleScope Avm.Authoring { (Resolve-AvmTool -Name mapotf).Path }
        $script:options = [pscustomobject]@{
            ToolPath    = $script:mapotf
            ProfileDirs = @{
                'unit-test-inspect' = Join-Path $moduleRoot 'Resources' 'mapotf' 'unit-test-inspect'
                'unit-test'         = Join-Path $moduleRoot 'Resources' 'mapotf' 'unit-test'
            }
            EnvVars     = @{}
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
            param($Fixture, [string[]] $Locations = @())
            InModuleScope Avm.Authoring -Parameters @{
                Fixture   = $Fixture
                Options   = $script:options
                Locations = $Locations
            } {
                param($Fixture, $Options, $Locations)
                $encoded = ConvertTo-Json -InputObject @($Locations) -Compress
                $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
                    'transform', '--tf-dir', $Fixture.Root, '--test-file', $Fixture.Scope.RelativePath,
                    '--mptf-dir', $Options.ProfileDirs['unit-test'],
                    '--mptf-var', "new_location_modules=$encoded"
                ) -WorkingDirectory $Fixture.Root
                $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
                    'clean-backup', '--tf-dir', $Fixture.Root, '--test-file', $Fixture.Scope.RelativePath
                ) -WorkingDirectory $Fixture.Root
            }
        }
    }

    AfterAll {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'inspects only known local declarations without writes or backups' {
        $fixture = New-NativeTestFixture
        $before = (Get-FileHash -LiteralPath $fixture.Test).Hash
        $data = Read-NativeTestFixture -Fixture $fixture
        $data.test.run_modules.root.kind | Should -BeExactly 'root'
        $data.test.run_modules.child.kind | Should -BeExactly 'local'
        $data.test.run_modules.root.dir | Should -BeExactly $fixture.Root
        $data.test.run_modules.child.dir | Should -BeExactly $fixture.Child
        $data.modules.Keys | Should -HaveCount 2
        $data.modules[$fixture.Root].variables.ContainsKey('location') | Should -BeFalse
        $data.test.mock_providers['azapi'].mptf.is_empty | Should -BeTrue
        $data.test.mock_providers['azapi.alternate'].mptf.is_empty | Should -BeFalse
        (Get-FileHash -LiteralPath $fixture.Test).Hash | Should -BeExactly $before
        @(Get-ChildItem -LiteralPath $fixture.Root -Recurse -Filter '*.mptfbackup') | Should -HaveCount 0
        (Join-Path $fixture.Root '.terraform') | Should -Not -Exist
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

    It 'inspects and migrates a module reached through a directory alias' {
        $fixture = New-NativeTestFixture
        $alias = Join-Path $TestDrive ('alias-' + [guid]::NewGuid().ToString('N'))
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $linkType -Path $alias -Target $fixture.Root
        $fixture.Root = $alias
        $fixture.Child = Join-Path $alias 'modules' 'child'
        $fixture.Test = Join-Path $alias 'tests' 'unit' 'scopes.tftest.hcl'
        $fixture.Targets[0].Path = $fixture.Root
        $fixture.Targets[1].Path = $fixture.Child
        $fixture.Scope.File = Get-Item -LiteralPath $fixture.Test
        $before = Read-NativeTestFixture -Fixture $fixture
        $before.test.run_modules.root.dir | Should -BeExactly $fixture.Root
        $before.test.run_modules.child.dir | Should -BeExactly $fixture.Child
        foreach ($target in $fixture.Targets) {
            [System.IO.File]::WriteAllText((Join-Path $target.Path 'location.tf'), "variable `"location`" {`n  type = string`n}`n", $script:utf8)
        }
        Invoke-NativeLocationProfile -Fixture $fixture -Locations @($before.test.run_modules.Values.dir)
        $after = Read-NativeTestFixture -Fixture $fixture
        $after.test.runs.root.variables[0].mptf.attributes.location | Should -BeExactly 'eastus'
        $after.test.runs.child.variables[0].mptf.attributes.location | Should -BeExactly 'eastus'
        $after.test.run_modules.child.dir | Should -BeExactly $fixture.Child
        $first = [System.IO.File]::ReadAllText($fixture.Test)
        Invoke-NativeLocationProfile -Fixture $fixture -Locations @($before.test.run_modules.Values.dir)
        [System.IO.File]::ReadAllText($fixture.Test) | Should -BeExactly $first
        @(Get-ChildItem -LiteralPath $fixture.Root -Recurse -Filter '*.mptfbackup') | Should -HaveCount 0
    }

    It 'preserves an explicitly authored global location' -TestCases @(
        @{ Value = '"uksouth"' }
        @{ Value = 'null' }
        @{ Value = 'var.authored_location' }
    ) {
        param($Value)
        $fixture = New-NativeTestFixture -GlobalLocation $Value
        $before = Read-NativeTestFixture -Fixture $fixture
        Invoke-NativeLocationProfile -Fixture $fixture -Locations @($fixture.Root, $fixture.Child)
        $after = Read-NativeTestFixture -Fixture $fixture
        $after.test.variables.mptf.attributes.ContainsKey('location') | Should -BeTrue
        $after.test.variables.mptf.attributes.location | Should -Be $before.test.variables.mptf.attributes.location
        $after.test.runs.root.ContainsKey('variables') | Should -BeFalse
        $after.test.runs.child.ContainsKey('variables') | Should -BeFalse
    }

    It 'preserves a run-specific location while filling only the other run' -TestCases @(
        @{ Value = '"uksouth"' }
        @{ Value = 'null' }
        @{ Value = 'run.setup.location' }
    ) {
        param($Value)
        $fixture = New-NativeTestFixture -RunLocation $Value
        $before = Read-NativeTestFixture -Fixture $fixture
        Invoke-NativeLocationProfile -Fixture $fixture -Locations @($fixture.Root, $fixture.Child)
        $after = Read-NativeTestFixture -Fixture $fixture
        $after.test.runs.root.variables[0].mptf.attributes.location |
            Should -Be $before.test.runs.root.variables[0].mptf.attributes.location
        $after.test.runs.root.variables[0].mptf.attributes.enable_telemetry | Should -BeFalse
        $after.test.runs.child.variables[0].mptf.attributes.location | Should -BeExactly 'eastus'
    }

    It 'does not invent inputs when no target acquired a new declaration' {
        $fixture = New-NativeTestFixture
        Invoke-NativeLocationProfile -Fixture $fixture
        $after = Read-NativeTestFixture -Fixture $fixture
        $after.test.variables.mptf.attributes.ContainsKey('location') | Should -BeFalse
        $after.test.runs.root.ContainsKey('variables') | Should -BeFalse
        $after.test.runs.child.ContainsKey('variables') | Should -BeFalse
    }

    It 'rejects remote targets without fetching them' {
        $fixture = New-NativeTestFixture
        $source = [System.IO.File]::ReadAllText($fixture.Test).Replace('./modules/child', 'example.invalid/unreachable/module')
        [System.IO.File]::WriteAllText($fixture.Test, $source, $script:utf8)
        { Read-NativeTestFixture -Fixture $fixture } | Should -Throw '*target must be a known local module*'
        [System.IO.File]::ReadAllText($fixture.Test) | Should -BeExactly $source
        (Join-Path $fixture.Root '.terraform') | Should -Not -Exist
    }

    It 'inspects a test file with no runs without requiring a module-source instance' {
        $fixture = New-NativeTestFixture
        $source = "mock_provider `"modtm`" {}`n"
        [System.IO.File]::WriteAllText($fixture.Test, $source, $script:utf8)
        $data = Read-NativeTestFixture -Fixture $fixture
        $data.test.runs.Count | Should -Be 0
        $data.test.run_modules.Count | Should -Be 0
        $data.modules.Count | Should -Be 0
        $data.test.mock_providers.modtm.mptf.is_empty | Should -BeTrue
        [System.IO.File]::ReadAllText($fixture.Test) | Should -BeExactly $source
    }

    It 'rejects a local directory outside the known module allowlist' {
        $fixture = New-NativeTestFixture
        $unknown = Join-Path $fixture.Root 'unknown'
        $null = New-Item -ItemType Directory -Path $unknown
        [System.IO.File]::WriteAllText((Join-Path $unknown 'main.tf'), 'locals {}', $script:utf8)
        $source = [System.IO.File]::ReadAllText($fixture.Test).Replace('./modules/child', './unknown')
        [System.IO.File]::WriteAllText($fixture.Test, $source, $script:utf8)
        { Read-NativeTestFixture -Fixture $fixture } | Should -Throw '*target must be a known local module*'
        [System.IO.File]::ReadAllText($fixture.Test) | Should -BeExactly $source
        (Join-Path $fixture.Root '.terraform') | Should -Not -Exist
    }
}
