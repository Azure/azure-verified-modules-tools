function New-UnitMigrationFixture {
        $root = Join-Path $TestDrive 'module with spaces, and=equals'
        $child = Join-Path $root 'modules' 'child'
        $targets = @(
            [pscustomobject]@{ Path = $root; Scope = 'root'; Profiles = @('root', 'module', 'common') }
            [pscustomobject]@{ Path = $child; Scope = 'module'; Profiles = @('root', 'module', 'common') }
        )
        $before = @{
            test    = @{
                variables      = $null
                runs           = @{
                    root  = @{ mptf = @{ attributes = @{ command = 'plan' } } }
                    child = @{ mptf = @{ attributes = @{ command = 'plan' } } }
                }
                run_modules    = @{
                    root  = @{ kind = 'root'; dir = $root; source = $null }
                    child = @{ kind = 'local'; dir = $child; source = './modules/child' }
                }
                mock_providers = @{
                    azapi = New-CustomTelemetryMock -Defaults @{
                        subscription_resource_id = '/subscriptions/00000000-0000-0000-0000-000000000000'
                    }
                }
                providers      = @{}
            }
            modules = @{
                $root  = @{ variables = @{} }
                $child = @{ variables = @{} }
            }
        }
        $after = $before | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        foreach ($target in $targets) {
            $after.modules[$target.Path].variables.location = @{ required = $true }
        }
        $scope = [pscustomobject]@{
            File         = [pscustomobject]@{
                Name     = 'scopes.tftest.hcl'
                FullName = Join-Path $root 'tests' 'unit' 'scopes.tftest.hcl'
            }
            Owner        = $targets[0]
            RelativePath = 'tests/unit/scopes.tftest.hcl'
            IsUnitTest   = $true
            Inspection   = $after
        }
        [pscustomobject]@{
            Root      = $root
            Child     = $child
            Targets   = $targets
            Scope     = $scope
            Before    = $before
            After     = $after
            Snapshots = @([pscustomobject]@{ Scope = $scope; Hash = 'before'; Before = $before })
            Options   = [pscustomobject]@{
                ToolPath       = Join-Path $TestDrive 'mapotf'
                TerraformPath  = Join-Path $TestDrive 'terraform'
                ProfileDirs    = @{
                    module              = Join-Path $TestDrive 'module-profile'
                    'provider-restore'  = Join-Path $TestDrive 'provider-restore'
                    'unit-test-inspect' = Join-Path $TestDrive 'inspection'
                    'unit-test'         = Join-Path $TestDrive 'location'
                }
                EnvVars        = @{}
                InspectionRoot = Join-Path $TestDrive ('provider-inspection-' + [guid]::NewGuid().ToString('N'))
            }
        }
    }

function Read-UnitMigrationInspection {
        param($Fixture, [string] $Json)
        if (-not $PSBoundParameters.ContainsKey('Json')) {
            $Json = $Fixture.After | ConvertTo-Json -Depth 20 -Compress
        }
        $Fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] = $Json
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $Fixture } {
            param($Fixture)
            Get-AvmTerraformUnitTestInspection -Scope $Fixture.Scope `
                -ModuleTargets $Fixture.Targets -Options $Fixture.Options
        }
    }

function Invoke-UnitMigrationFixture {
        param($Fixture, [switch] $WhatIf, [AllowEmptyString()] [string] $TestContent)
        $directory = Split-Path -Parent $Fixture.Scope.File.FullName
        $null = New-Item -ItemType Directory -Path $directory -Force
        $conditions = @(
            foreach ($run in $Fixture.After.test.runs.get_Values()) {
                if ($run.Contains('assert')) {
                    foreach ($assertion in $run.assert) {
                        if ($assertion -is [System.Collections.IDictionary] -and
                            $assertion['mptf'] -is [System.Collections.IDictionary] -and
                            $assertion.mptf['attributes'] -is [System.Collections.IDictionary]) {
                            [string]$assertion.mptf.attributes['condition']
                        }
                    }
                }
            }
        )
        if (-not $PSBoundParameters.ContainsKey('TestContent')) {
            $TestContent = $conditions -join "`n"
        }
        [System.IO.File]::WriteAllText($Fixture.Scope.File.FullName, $TestContent, [System.Text.UTF8Encoding]::new($false))
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $Fixture; DryRun = [bool]$WhatIf } {
            param($Fixture, $DryRun)
            Invoke-AvmTerraformUnitTestMigration -Root $Fixture.Root -ModuleTargets $Fixture.Targets `
                -Snapshots $Fixture.Snapshots -Options $Fixture.Options -WhatIf:$DryRun
        }
    }

function New-CustomTelemetryMock {
        param([object] $Defaults = @{}, [string] $Alias)
        $attributes = @{}
        if ($Alias) { $attributes.alias = $Alias }
        @{
            mptf      = @{
                is_empty = $false
                attributes = $attributes
                block_type = 'mock_provider'
                block_labels = @('azapi')
                block_address = if ($Alias) { "mock_provider.azapi.$Alias" } else { 'mock_provider.azapi' }
            }
            mock_data = @(
                @{
                    mptf = @{
                        block_labels = @('azapi_client_config')
                        attributes   = @{ defaults = $Defaults }
                    }
                },
                @{
                    mptf = @{
                        block_labels = @('azapi_resource_list')
                        attributes   = @{ defaults = @{ output = @{ value = @() } } }
                    }
                }

            )
        }
    }

function New-UnitProviderAlias {
        param([string] $Provider, [string] $Alias = 'unit')
        @{
            mptf = @{
                is_empty = $false
                attributes = @{ alias = $Alias }
                block_type = 'mock_provider'
                block_labels = @($Provider)
                block_address = "mock_provider.$Provider.$Alias"
            }
        }
    }
