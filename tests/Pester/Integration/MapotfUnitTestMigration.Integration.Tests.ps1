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
                    $arguments += @('--mptf-var', ('telemetry_subscription_resource_id=' +
                        (ConvertTo-Json -InputObject $ResourceId -Compress)))
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

    It 'preserves customized mock siblings while handling <Shape> client defaults' -TestCases @(
        @{ Shape = 'missing'; ExpectedId = '/subscriptions/00000000-0000-0000-0000-000000000000' }
        @{ Shape = 'empty'; ExpectedId = '/subscriptions/00000000-0000-0000-0000-000000000000' }
        @{ Shape = 'partial'; ExpectedId = '/subscriptions/11111111-1111-1111-1111-111111111111' }
        @{ Shape = 'complete'; ExpectedId = '/subscriptions/33333333-3333-3333-3333-333333333333' }
    ) {
        param($Shape, $ExpectedId)
        $fixture = New-NativeTestFixture
        $original = [System.IO.File]::ReadAllText($fixture.Test)
        $client = switch ($Shape) {
            missing { '' }
            empty { '  mock_data "azapi_client_config" {}' }
            partial {
                @'
  mock_data "azapi_client_config" {
    defaults = {
      # Keep the authored identity defaults.
      subscription_id = "11111111-1111-1111-1111-111111111111"
      object_id       = "44444444-4444-4444-4444-444444444444"
      tenant_id       = "22222222-2222-2222-2222-222222222222"
    }
  }
'@
            }
            complete {
                @'
  mock_data "azapi_client_config" {
    defaults = {
      subscription_id          = "11111111-1111-1111-1111-111111111111"
      subscription_resource_id = "/subscriptions/33333333-3333-3333-3333-333333333333"
    }
  }
'@
            }
        }
        $source = @'
mock_provider "azapi" {
  mock_data "azapi_resource_list" {
    defaults = { output = { value = [] } }
  }
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/authored"
    }
  }
__CLIENT__
}

'@
        $source = $source.Replace('__CLIENT__', $client) +
            $original.Substring($original.IndexOf('variables {', [System.StringComparison]::Ordinal))
        [System.IO.File]::WriteAllText($fixture.Test, $source, $script:utf8)
        $before = Read-NativeTestFixture -Fixture $fixture
        $untouched = Join-Path $fixture.Root 'tests' 'unit' 'untouched.tftest.hcl'
        $untouchedHash = (Get-FileHash -LiteralPath $untouched).Hash
        $resourceId = InModuleScope Avm.Authoring -Parameters @{ Test = $before.test; Path = $fixture.Test } {
            param($Test, $Path)
            Get-AvmTerraformTelemetryMockResourceId -Test $Test -Path $Path
        }
        if ($Shape -eq 'complete') {
            $resourceId | Should -BeNullOrEmpty
        }
        else {
            $resourceId | Should -BeExactly $ExpectedId
        }
        Invoke-NativeLocationProfile -Fixture $fixture -ResourceId $resourceId
        $after = Read-NativeTestFixture -Fixture $fixture
        $mock = $after.test.mock_providers.azapi
        $clientConfigs = @($mock.mock_data | Where-Object { $_.mptf.block_labels[0] -ceq 'azapi_client_config' })
        $clientConfigs | Should -HaveCount 1
        $clientConfigs[0].mptf.attributes.defaults.subscription_resource_id | Should -BeExactly $ExpectedId
        ($mock.mock_data[0].mptf.attributes | ConvertTo-Json -Depth 20 -Compress) |
            Should -BeExactly ($before.test.mock_providers.azapi.mock_data[0].mptf.attributes | ConvertTo-Json -Depth 20 -Compress)
        ($mock.mock_resource[0].mptf.attributes | ConvertTo-Json -Depth 20 -Compress) |
            Should -BeExactly ($before.test.mock_providers.azapi.mock_resource[0].mptf.attributes | ConvertTo-Json -Depth 20 -Compress)
        foreach ($name in @('root', 'child')) {
            $after.test.run_modules[$name].source | Should -BeExactly $before.test.run_modules[$name].source
            $after.test.runs[$name].assert[0].mptf.attributes.condition |
                Should -BeExactly $before.test.runs[$name].assert[0].mptf.attributes.condition
        }
        $after.test.variables.mptf.attributes.enable_telemetry | Should -BeFalse
        $after.test.variables.mptf.attributes.hub_regions.primary | Should -BeExactly 'westeurope'
        $after.test.variables.mptf.attributes.hub_regions.secondary | Should -BeExactly 'swedencentral'
        if ($Shape -eq 'partial') {
            $defaults = $clientConfigs[0].mptf.attributes.defaults
            $defaults.subscription_id | Should -BeExactly '11111111-1111-1111-1111-111111111111'
            $defaults.tenant_id | Should -BeExactly '22222222-2222-2222-2222-222222222222'
            $defaults.object_id | Should -BeExactly $before.test.mock_providers.azapi.mock_data[1].mptf.attributes.defaults.object_id
            [System.IO.File]::ReadAllText($fixture.Test) | Should -Match '# Keep the authored identity defaults\.'
        }
        (Get-FileHash -LiteralPath $untouched).Hash | Should -BeExactly $untouchedHash
        $first = [System.IO.File]::ReadAllText($fixture.Test)
        Invoke-NativeLocationProfile -Fixture $fixture -ResourceId '/subscriptions/99999999-9999-9999-9999-999999999999'
        [System.IO.File]::ReadAllText($fixture.Test) | Should -BeExactly $first
        @(Get-ChildItem -LiteralPath $fixture.Root -Recurse -Filter '*.mptfbackup') | Should -HaveCount 0
    }

    It 'preserves unresolved mock-default expressions by requiring review' -TestCases @(
        @{ Defaults = 'var.client_defaults' }
        @{ Defaults = '{ subscription_id = "11111111-1111-1111-1111-111111111111", object_id = var.authored_object_id }' }
    ) {
        param($Defaults)
        $fixture = New-NativeTestFixture
        $source = @"
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = $Defaults
  }
}
run "root" { command = plan }
"@
        [System.IO.File]::WriteAllText($fixture.Test, $source, $script:utf8)
        $inspection = Read-NativeTestFixture -Fixture $fixture
        {
            InModuleScope Avm.Authoring -Parameters @{ Test = $inspection.test; Path = $fixture.Test } {
                param($Test, $Path)
                Get-AvmTerraformTelemetryMockResourceId -Test $Test -Path $Path
            }
        } | Should -Throw '*statically inspectable object literal*'
        [System.IO.File]::ReadAllText($fixture.Test) | Should -BeExactly $source
        @(Get-ChildItem -LiteralPath $fixture.Root -Recurse -Filter '*.mptfbackup') | Should -HaveCount 0
    }

    It 'rejects a selected profile without <Capability> before retiring any mock' -TestCases @(
        @{ Capability = 'label matching'; Setting = 'match_nested_block_labels' }
        @{ Capability = 'object merging'; Setting = 'merge_object_attributes' }
    ) {
        param($Setting)
        $fixture = New-NativeTestFixture
        $source = @'
mock_provider "modtm" {}
mock_provider "azapi" {
  mock_resource "azapi_resource" {}
}
run "root" { command = plan }
'@
        [System.IO.File]::WriteAllText($fixture.Test, $source, $script:utf8)
        $before = Read-NativeTestFixture -Fixture $fixture
        $untouched = Join-Path $fixture.Root 'tests' 'unit' 'untouched.tftest.hcl'
        $untouchedHash = (Get-FileHash -LiteralPath $untouched).Hash
        $profile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $profile
        foreach ($file in Get-ChildItem -LiteralPath $script:options.ProfileDirs['unit-test'] -File) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $profile $file.Name)
        }
        $rule = Join-Path $profile 'telemetry.mptf.hcl'
        $content = [System.IO.File]::ReadAllText($rule)
        $content = [regex]::Replace($content, "(?m)^([ \t]*$Setting[ \t]*=[ \t]*)true(?=\r?$)", '${1}false')
        $content | Should -Match "(?m)^[ \t]*$Setting[ \t]*=[ \t]*false(?=\r?$)"
        [System.IO.File]::WriteAllText($rule, $content, $script:utf8)
        $options = [pscustomobject]@{
            ToolPath = $script:options.ToolPath
            ProfileDirs = @{
                'unit-test-inspect' = $script:options.ProfileDirs['unit-test-inspect']
                'unit-test' = $profile
            }
            EnvVars = @{}
        }
        $snapshot = [pscustomobject]@{
            Scope = $fixture.Scope
            Hash = (Get-FileHash -LiteralPath $fixture.Test).Hash
            Before = $before
        }
        {
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $fixture; Options = $options; Snapshot = $snapshot } {
                param($Fixture, $Options, $Snapshot)
                Invoke-AvmTerraformUnitTestMigration -Root $Fixture.Root -ModuleTargets $Fixture.Targets `
                    -Snapshots @($Snapshot) -Options $Options
            }
        } | Should -Throw '*label-safe object merging*'
        [System.IO.File]::ReadAllText($fixture.Test) | Should -BeExactly $source
        (Get-FileHash -LiteralPath $untouched).Hash | Should -BeExactly $untouchedHash
        @(Get-ChildItem -LiteralPath $fixture.Root -Recurse -Filter '*.mptfbackup') | Should -HaveCount 0
    }
}
