#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:terraformMetadata = '{"canonicalType":"Microsoft.Resources/resourceGroups","telemetryIdPrefix":"46d3xtrf.res.a1b2c3d"}'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTerraformTransform' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("tf-mod-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Value 'resource "null_resource" "x" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'variables.tf') -Value 'variable "y" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'README.md') -Value '# readme' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'metadata.json') -Value $script:terraformMetadata -Encoding utf8NoBOM

        $script:context = [pscustomobject][ordered]@{
            Kind      = 'terraform-module-repo'
            Root      = $script:moduleDir
            Ecosystem = 'terraform'
            Source    = 'path-heuristic'
        }
        Mock Set-AvmTelemetryTagLintDirective -ModuleName 'Avm.Authoring'
        Mock Get-AvmTerraformUnitTestSnapshot -ModuleName 'Avm.Authoring' { @() }
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
                Invoke-AvmTerraformTransform -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'runs root, module, and common profiles for the root then cleans backups' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { "/fake/$ProfileName" }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C
        }
        $result.Engine         | Should -Be 'terraform'
        $result.Tool           | Should -Be 'mapotf/0.1.5'
        $result.ToolPath       | Should -Be '/fake/mapotf'
        $result.ToolSource     | Should -Be 'cache'
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 2
        @($result.Changed).Count | Should -Be 0
        @($result.Issues).Count  | Should -Be 0

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/mapotf' -and
                $ArgumentList[0] -eq 'transform' -and
                ([array]::IndexOf($ArgumentList, '/fake/root')) -lt ([array]::IndexOf($ArgumentList, '/fake/module')) -and
                ([array]::IndexOf($ArgumentList, '/fake/module')) -lt ([array]::IndexOf($ArgumentList, '/fake/common')) -and
                $ArgumentList -contains '--tf-dir' -and
                [string]::IsNullOrWhiteSpace([string]$EnvVars['TF_PLUGIN_CACHE_DIR']) -and
                -not [string]::IsNullOrWhiteSpace([string]$EnvVars['MAPOTF_PROVIDER_SCHEMA_CACHE_DIR'])
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'transform' -and
                $ArgumentList -contains '/fake/module-call' -and
                $ArgumentList -contains '/fake/common'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/mapotf' -and
                $ArgumentList[0] -eq 'clean-backup' -and
                $ArgumentList -contains '--tf-dir'
            }
            Should -Invoke Set-AvmTelemetryTagLintDirective -Exactly 1
        }
    }

    It 'runs example rules before common rules without applying them to modules' {
        $ctx = $script:context
        $example = Join-Path $ctx.Root 'examples' 'default'
        $child = Join-Path $ctx.Root 'modules' 'child'
        New-Item -ItemType Directory -Path $example, $child -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $example 'main.tf') -Value 'locals {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $child 'terraform.tf') -Value 'terraform {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $child 'metadata.json') -Value $script:terraformMetadata -Encoding utf8NoBOM

        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; Example = $example } {
            param($C, $Example)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name"
                }
            }
            Mock Resolve-AvmMapotfConfigDir { "/fake/$ProfileName" }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }

            Invoke-AvmTerraformTransform -Context $C | Out-Null

            Should -Invoke Get-AvmTerraformUnitTestSnapshot -Exactly 1 -ParameterFilter {
                $ModuleTargets.Count -eq 3 -and
                @($ModuleTargets | Where-Object { $_.Path -ceq $Example -and $_.Profiles -contains 'example' }).Count -eq 1
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'transform' -and
                $WorkingDirectory -eq $Example -and
                $ArgumentList -contains '/fake/example' -and
                $ArgumentList -contains '/fake/common' -and
                ([array]::IndexOf($ArgumentList, '/fake/example')) -lt ([array]::IndexOf($ArgumentList, '/fake/common')) -and
                $ArgumentList -notcontains '/fake/root' -and
                $ArgumentList -notcontains '/fake/module'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 4 -ParameterFilter {
                $ArgumentList[0] -eq 'transform' -and
                $WorkingDirectory -ne $Example -and
                $ArgumentList -notcontains '/fake/example'
            }
        }
    }

    It 'finishes module targets and forwards child inputs before parent and example scopes' {
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = $Name; Version = 'test'; Platform = 'test'
                    Source = 'cache'; Path = "/fake/$Name"
                }
            }
            Mock Resolve-AvmMapotfConfigDir { "/fake/$ProfileName" }
            Mock Get-AvmTerraformTransformTarget {
                @(
                    [pscustomobject]@{ Path = $C.Root; Scope = 'root'; Profiles = @('root', 'module', 'common') }
                    [pscustomobject]@{ Path = '/fake/module'; Scope = 'module'; Profiles = @('module', 'common') }
                    [pscustomobject]@{ Path = '/fake/example'; Scope = 'example'; Profiles = @('example', 'provider-cleanup', 'common') }
                    [pscustomobject]@{ Path = '/fake/second-example'; Scope = 'example'; Profiles = @('example', 'provider-cleanup', 'common') }
                )
            }
            $script:transformBatches = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-AvmParallel { $script:transformBatches.Add(($InputObject.Scope -join ',')) }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Mock Get-AvmRemainingModtmIssue { @() }

            Invoke-AvmTerraformTransform -Context $C -ThrottleLimit 4 | Out-Null

            Should -Invoke Invoke-AvmParallel -Exactly 2 -ParameterFilter {
                $FunctionName -eq 'Invoke-AvmMapotfTransformTarget' -and
                $InputObject.Count -eq 2 -and
                $ThrottleLimit -eq 4
            }
            $script:transformBatches.ToArray() | Should -Be @('root,module', 'module', 'root', 'example,example')
        }
    }

    It 'unsets an ambient shared plugin cache for every transform phase' {
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            $savedPluginCache = $env:TF_PLUGIN_CACHE_DIR
            try {
                $env:TF_PLUGIN_CACHE_DIR = '/fake/plugin-cache'
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = $Name; Version = 'test'; Platform = 'test'
                        Source = 'cache'; Path = "/fake/$Name"
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { "/fake/$ProfileName" }
                Mock Get-AvmTerraformTransformTarget {
                    @(
                        [pscustomobject]@{ Path = $C.Root; Scope = 'root'; Profiles = @('root', 'module', 'common') }
                        [pscustomobject]@{ Path = '/fake/example'; Scope = 'example'; Profiles = @('example', 'provider-cleanup', 'common') }
                        [pscustomobject]@{ Path = '/fake/test'; Scope = 'test'; Profiles = @('provider-cleanup', 'test') }
                    )
                }
                Mock Invoke-AvmParallel
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                Mock Get-AvmRemainingModtmIssue { @() }

                Invoke-AvmTerraformTransform -Context $C -ThrottleLimit 4 | Out-Null

                Should -Invoke Invoke-AvmParallel -Exactly 4 -ParameterFilter {
                    $ThrottleLimit -eq 4 -and
                    [string]::IsNullOrWhiteSpace([string]$Argument.EnvVars.TF_PLUGIN_CACHE_DIR)
                }
                $env:TF_PLUGIN_CACHE_DIR | Should -Be '/fake/plugin-cache'
            }
            finally {
                $env:TF_PLUGIN_CACHE_DIR = $savedPluginCache
            }
        }
    }

    It 'removes competing terraform binaries from the child PATH without mutating the caller PATH' {
        $ctx = $script:context
        $entrypoint = if ([OperatingSystem]::IsWindows()) { 'terraform.exe' } else { 'terraform' }
        $pinnedDir = Join-Path $TestDrive 'pinned-terraform'
        $strayDir = Join-Path $TestDrive 'stray-terraform'
        $safeDir = Join-Path $TestDrive 'safe-bin'
        New-Item -ItemType Directory -Path $pinnedDir, $strayDir, $safeDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $pinnedDir $entrypoint), (Join-Path $strayDir $entrypoint) -Force | Out-Null
        $injectedPath = @($strayDir, $safeDir, $pinnedDir) -join [System.IO.Path]::PathSeparator

        $originalPath = $env:PATH
        try {
            $env:PATH = $injectedPath
            $observedPath = InModuleScope 'Avm.Authoring' -Parameters @{
                C = $ctx
                P = (Join-Path $pinnedDir $entrypoint)
            } {
                param($C, $P)
                Mock Resolve-AvmTool {
                    if ($Name -eq 'terraform') {
                        [pscustomobject]@{
                            Name = 'terraform'; Version = '1.15.8'; Platform = 'test'
                            Source = 'cache'; Path = $P
                        }
                    }
                    else {
                        [pscustomobject]@{
                            Name = 'mapotf'; Version = '0.1.5'; Platform = 'test'
                            Source = 'cache'; Path = (Join-Path $TestDrive 'mapotf')
                        }
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { $TestDrive }
                Mock Invoke-AvmProcess {
                    $script:childPath = $EnvVars['PATH']
                    [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                Invoke-AvmTerraformTransform -Context $C | Out-Null
                return $script:childPath
            }

            $entries = @($observedPath -split [regex]::Escape([string][System.IO.Path]::PathSeparator))
            $entries[0] | Should -Be $pinnedDir
            $entries | Should -Contain $safeDir
            $entries | Should -Not -Contain $strayDir
            @($entries | Where-Object {
                    Test-Path -LiteralPath (Join-Path $_ $entrypoint) -PathType Leaf
                }).Count | Should -Be 1
            $env:PATH | Should -Be $injectedPath
        }
        finally {
            $env:PATH = $originalPath
        }
    }

    It 'reports the files mapotf changed in the Changed array' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Add-Content -LiteralPath (Join-Path $tfDir 'main.tf') -Value '# rewritten by mapotf'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C
        }
        $result.Status           | Should -Be 'pass'
        @($result.Changed).Count | Should -Be 1
        $result.Changed[0]       | Should -Be 'main.tf'
        @($result.Issues).Count  | Should -Be 0
    }

    It 'fails when an author-owned modtm resource remains after migration' {
        $script:context | Should -Not -BeNullOrEmpty
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Encoding utf8NoBOM -Value @'
resource "modtm_custom" "authored" {}
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmMapotfConfigDir { "/fake/$ProfileName" }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C
        }

        $result.Status | Should -Be 'fail'
        $result.Issues | Should -HaveCount 1
        $result.Issues[0].File | Should -BeExactly 'main.tf'
        $result.Issues[0].Line | Should -Be 1
        $result.Issues[0].Code | Should -BeExactly 'avm.tf.modtm-remains'
    }

    It 'reports author-owned modtm data in an example instead of removing its provider' {
        $example = Join-Path $script:moduleDir 'examples' 'default'
        $null = New-Item -ItemType Directory -Path $example -Force
        Set-Content -LiteralPath (Join-Path $example 'main.tf') -Encoding utf8NoBOM -Value @'
data "modtm_module_source" "custom" {
  module_path = path.module
}
'@

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmMapotfConfigDir { "/fake/$ProfileName" }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C
        }

        $result.Status | Should -Be 'fail'
        $result.Issues | Should -HaveCount 1
        $result.Issues[0].File.Replace('\', '/') | Should -BeExactly 'examples/default/main.tf'
        $result.Issues[0].Code | Should -BeExactly 'avm.tf.modtm-remains'
    }

    It 'rewrites standard modtm mocks and references in Terraform test files' {
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'telemetry.tftest.hcl'
        Set-Content -LiteralPath $testFile -Encoding utf8NoBOM -Value @'
mock_provider "modtm" {}
mock_provider "random" {}
mock_provider "azapi" {}

run "telemetry" {
  assert {
    condition     = can(modtm_telemetry.telemetry[0])
    error_message = "Telemetry must be created."
  }
}
'@

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmMapotfConfigDir { "/fake/$ProfileName" }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C
        }

        $result.Status | Should -Be 'pass'
        $result.Changed | Should -Contain ([System.IO.Path]::Combine('tests', 'unit', 'telemetry.tftest.hcl'))
        $updated = Get-Content -LiteralPath $testFile -Raw
        $updated | Should -Not -Match 'mock_provider "modtm"'
        $updated | Should -Not -Match 'mock_provider "random"'
        [regex]::Matches($updated, 'mock_provider "azapi"').Count | Should -Be 1
        $updated | Should -Match 'can\(azapi_resource\.telemetry\[0\]\)'
        $result.FilesProcessed | Should -Be 3
    }

    It 'preserves random mocks when a real random resource or requirement remains' -TestCases @(
        @{ Source = 'resource "random_string" "suffix" { length = 4 }'; SourceFile = 'main.tf' }
        @{ Source = 'terraform { required_providers { random = { source = "hashicorp/random" } } }'; SourceFile = 'main.tf' }
        @{ Source = '{"resource":{"random_string":{"suffix":{"length":4}}}}'; SourceFile = 'generated.tf.json' }
    ) {
        param($Source, $SourceFile)
        Add-Content -LiteralPath (Join-Path $script:moduleDir $SourceFile) -Value $Source
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'random.tftest.hcl'
        Set-Content -LiteralPath $testFile -Value 'mock_provider "random" {}' -Encoding utf8NoBOM
        $before = [System.IO.File]::ReadAllBytes($testFile)

        InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir } {
            param($Root)
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                [pscustomobject]@{ Path = $Root; Profiles = @('root') })
        }

        [System.IO.File]::ReadAllBytes($testFile) | Should -Be $before
    }

    It 'provides valid AzAPI unit data for a standard telemetry mock exactly once' -TestCases @(
        @{ Provider = 'modtm' }
        @{ Provider = 'azapi' }
    ) {
        param($Provider)
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'telemetry.tftest.hcl'
        Set-Content -LiteralPath $testFile -Value "mock_provider `"$Provider`" {}" -Encoding utf8NoBOM

        $firstPass = InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir; TestPath = $testFile } {
            param($Root, $TestPath)
            $targets = @([pscustomobject]@{ Path = $Root; Profiles = @('root') })
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets $targets
            $firstPass = [System.IO.File]::ReadAllText($TestPath)
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets $targets
            return $firstPass
        }

        $updated = [System.IO.File]::ReadAllText($testFile)
        $updated | Should -BeExactly $firstPass
        $updated | Should -Not -Match 'mock_provider "modtm"'
        [regex]::Matches($updated, 'mock_provider "azapi"').Count | Should -Be 1
        $updated | Should -Match 'subscription_resource_id\s*=\s*"/subscriptions/00000000-0000-0000-0000-000000000000"'
    }

    It 'preserves an authored AzAPI mock while retiring modtm' {
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'telemetry.tftest.hcl'
        $mock = @'
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = { subscription_id = "11111111-1111-1111-1111-111111111111" }
  }
}
'@
        Set-Content -LiteralPath $testFile -Value ($mock + "`nmock_provider `"modtm`" {}`n") -Encoding utf8NoBOM
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir } {
            param($Root)
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                [pscustomobject]@{ Path = $Root; Profiles = @('root') })
        }
        ([System.IO.File]::ReadAllText($testFile)).TrimEnd() | Should -BeExactly $mock.TrimEnd()
    }

    It 'rejects ambiguous replacement-provider mocks without rewriting the file' -TestCases @(
        @{ Extra = 'provider "azapi" {}' }
        @{ Extra = "run `"setup`" {`n  module { source = `"./setup`" }`n}`n" }
        @{ Extra = "run `"mapped`" {`n  providers = { modtm = modtm }`n}`n" }
        @{ Extra = 'mock_provider "azapi" { alias = "alternate" }' }
        @{ Extra = "mock_provider `"azapi`" { source = `"./mocks`" }`nrun `"mapped`" {`n  providers = { modtm = modtm }`n}`n" }
        @{ Extra = "mock_provider `"azapi`" { source = `"./mocks`" }`nrun `"setup`" {`n  module { source = `"./setup`" }`n}`n" }
    ) {
        param($Extra)
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'telemetry.tftest.hcl'
        Set-Content -LiteralPath $testFile -Value ("mock_provider `"modtm`" {}`n" + $Extra) -Encoding utf8NoBOM
        $before = [System.IO.File]::ReadAllBytes($testFile)
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir } {
                param($Root)
                Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                    [pscustomobject]@{ Path = $Root; Profiles = @('root') })
            }
        } | Should -Throw '*Cannot automatically migrate telemetry mocks*'
        [System.IO.File]::ReadAllBytes($testFile) | Should -Be $before
    }

    It 'does not introduce a mocked provider into an integration test' {
        $testDir = Join-Path $script:moduleDir 'tests' 'integration'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'telemetry.tftest.hcl'
        Set-Content -LiteralPath $testFile -Value 'mock_provider "modtm" {}' -Encoding utf8NoBOM
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir } {
            param($Root)
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                [pscustomobject]@{ Path = $Root; Profiles = @('root') })
        }
        [System.IO.File]::ReadAllText($testFile) | Should -Not -Match 'mock_provider'
    }

    It 'preserves random mocks when a module dependency is not scanned' -TestCases @(
        @{ Source = 'Azure/naming/azurerm' }
        @{ Source = './unscanned-child' }
        @{ Source = '../shared' }
        @{ Source = './unscanned-child'; Header = 'module /* child */ "dependency"' }
        @{ Source = './unscanned-child'; Header = "module`n`"dependency`"" }
    ) {
        param($Source, $Header = 'module "dependency"')
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Encoding utf8NoBOM `
            -Value "$Header {`n  source = `"$Source`"`n}`n"
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'random.tftest.hcl'
        Set-Content -LiteralPath $testFile -Value 'mock_provider "random" {}' -Encoding utf8NoBOM
        $before = [System.IO.File]::ReadAllBytes($testFile)

        InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir } {
            param($Root)
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                [pscustomobject]@{ Path = $Root; Profiles = @('root') })
        }

        [System.IO.File]::ReadAllBytes($testFile) | Should -Be $before
    }

    It 'removes an obsolete mock when known local dependencies do not use random' {
        $child = Join-Path $script:moduleDir 'modules' 'child'
        $null = New-Item -ItemType Directory -Path $child -Force
        Set-Content -LiteralPath (Join-Path $child 'main.tf') -Encoding utf8NoBOM -Value 'locals {}'
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Encoding utf8NoBOM `
            -Value "module `"child`" {`n  source = `"./modules/child`"`n}`n"
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'random.tftest.hcl'
        Set-Content -LiteralPath $testFile -Value 'mock_provider "random" {}' -Encoding utf8NoBOM

        InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir; Child = $child } {
            param($Root, $Child)
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                [pscustomobject]@{ Path = $Root; Profiles = @('root') }
                [pscustomobject]@{ Path = $Child; Profiles = @('module') })
        }

        Get-Content -LiteralPath $testFile -Raw | Should -Not -Match 'mock_provider "random"'
    }

    It 'preserves random mocks when a local child still uses the provider' {
        $child = Join-Path $script:moduleDir 'modules' 'child'
        $null = New-Item -ItemType Directory -Path $child -Force
        Set-Content -LiteralPath (Join-Path $child 'main.tf') -Encoding utf8NoBOM `
            -Value 'resource "random_string" "suffix" { length = 4 }'
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'random.tftest.hcl'
        Set-Content -LiteralPath $testFile -Value 'mock_provider "random" {}' -Encoding utf8NoBOM

        InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir; Child = $child } {
            param($Root, $Child)
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                [pscustomobject]@{ Path = $Root; Profiles = @('root') }
                [pscustomobject]@{ Path = $Child; Profiles = @('module') })
        }

        Get-Content -LiteralPath $testFile -Raw | Should -Match 'mock_provider "random"'
    }

    It 'preserves random mocks when a unit test setup still uses the provider' -TestCases @(
        @{ SourceFile = 'main.tf'; Source = 'resource "random_string" "suffix" { length = 4 }' }
        @{ SourceFile = 'main.tf.json'; Source = '{"resource":{"random_string":{"suffix":{"length":4}}}}' }
    ) {
        param($SourceFile, $Source)
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $setup = Join-Path $testDir 'setup'
        $null = New-Item -ItemType Directory -Path $setup -Force
        Set-Content -LiteralPath (Join-Path $setup $SourceFile) -Encoding utf8NoBOM -Value $Source
        $testFile = Join-Path $testDir 'random.tftest.hcl'
        Set-Content -LiteralPath $testFile -Value 'mock_provider "random" {}' -Encoding utf8NoBOM

        InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir } {
            param($Root)
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                [pscustomobject]@{ Path = $Root; Profiles = @('root') })
        }

        Get-Content -LiteralPath $testFile -Raw | Should -Match 'mock_provider "random"'
    }

    It 'removes an obsolete unit mock without touching example-owned random resources' {
        $example = Join-Path $script:moduleDir 'examples' 'default'
        $null = New-Item -ItemType Directory -Path $example -Force
        Set-Content -LiteralPath (Join-Path $example 'main.tf') -Encoding utf8NoBOM `
            -Value 'resource "random_integer" "region" { min = 1; max = 3 }'
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'random.tftest.hcl'
        Set-Content -LiteralPath $testFile -Value 'mock_provider "random" {}' -Encoding utf8NoBOM

        InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir; Example = $example } {
            param($Root, $Example)
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                [pscustomobject]@{ Path = $Root; Profiles = @('root') }
                [pscustomobject]@{ Path = $Example; Profiles = @('example', 'provider-cleanup', 'common') })
        }

        Get-Content -LiteralPath $testFile -Raw | Should -Not -Match 'mock_provider "random"'
        Get-Content -LiteralPath (Join-Path $example 'main.tf') -Raw |
            Should -Match 'resource "random_integer"'
    }

    It 'checks random use in the selected example without including other examples' -TestCases @(
        @{ UsesRandom = $true }
        @{ UsesRandom = $false }
    ) {
        param($UsesRandom)
        $example = Join-Path $script:moduleDir 'examples' 'selected'
        $unselected = Join-Path $script:moduleDir 'examples' 'unselected'
        $unit = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $example, $unselected, $unit -Force
        $source = if ($UsesRandom) { 'resource "random_string" "suffix" { length = 4 }' } else { 'locals {}' }
        Set-Content -LiteralPath (Join-Path $example 'main.tf') -Encoding utf8NoBOM -Value $source
        Set-Content -LiteralPath (Join-Path $unselected 'main.tf') -Encoding utf8NoBOM `
            -Value 'resource "random_string" "suffix" { length = 4 }'
        $testFile = Join-Path $unit 'selected.tftest.hcl'
        Set-Content -LiteralPath $testFile -Encoding utf8NoBOM -Value @'
mock_provider "modtm" {}
mock_provider "random" {}
run "selected" {
  module {
    source = "./examples/selected"
  }
}
'@
        InModuleScope Avm.Authoring -Parameters @{
            Root = $script:moduleDir
            Example = $example
            Unselected = $unselected
            TestFile = $testFile
        } {
            param($Root, $Example, $Unselected, $TestFile)
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                [pscustomobject]@{ Path = $Root; Profiles = @('root') }
                [pscustomobject]@{ Path = $Example; Profiles = @('example', 'provider-cleanup', 'common') }
                [pscustomobject]@{ Path = $Unselected; Profiles = @('example', 'provider-cleanup', 'common') }
            ) -UnitTestPlans @(
                [pscustomobject]@{ Path = $TestFile; TargetPaths = @($Example) }
            )
        }
        $updated = [System.IO.File]::ReadAllText($testFile)
        $updated | Should -Not -Match 'mock_provider "modtm"'
        $updated | Should -Match 'mock_provider "azapi"'
        $updated | Should -Match 'source = "\./examples/selected"'
        [regex]::IsMatch($updated, 'mock_provider "random"') | Should -Be $UsesRandom
    }

    It 'migrates a native-validated sibling target and checks its actual random use' -TestCases @(
        @{ UsesRandom = $true }
        @{ UsesRandom = $false }
    ) {
        param($UsesRandom)
        $owner = Join-Path $script:moduleDir 'modules' 'owner'
        $sibling = Join-Path $script:moduleDir 'modules' 'sibling'
        $unit = Join-Path $owner 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $unit, $sibling -Force
        Set-Content -LiteralPath (Join-Path $owner 'main.tf') -Encoding utf8NoBOM -Value 'locals {}'
        $source = if ($UsesRandom) { 'resource "random_string" "suffix" { length = 4 }' } else { 'locals {}' }
        Set-Content -LiteralPath (Join-Path $sibling 'main.tf') -Encoding utf8NoBOM -Value $source
        $testFile = Join-Path $unit 'sibling.tftest.hcl'
        Set-Content -LiteralPath $testFile -Encoding utf8NoBOM -Value @'
mock_provider "modtm" {}
mock_provider "random" {}
run "sibling" {
  module {
    source = "../sibling"
  }
}
'@
        InModuleScope Avm.Authoring -Parameters @{
            Root = $script:moduleDir
            Owner = $owner
            Sibling = $sibling
            TestFile = $testFile
        } {
            param($Root, $Owner, $Sibling, $TestFile)
            Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                [pscustomobject]@{ Path = $Root; Profiles = @('root') }
                [pscustomobject]@{ Path = $Owner; Profiles = @('module') }
                [pscustomobject]@{ Path = $Sibling; Profiles = @('root', 'module') }
            ) -UnitTestPlans @(
                [pscustomobject]@{ Path = $TestFile; TargetPaths = @($Sibling) }
            )
        }
        $updated = [System.IO.File]::ReadAllText($testFile)
        $updated | Should -Not -Match 'mock_provider "modtm"'
        $updated | Should -Match 'mock_provider "azapi"'
        $updated | Should -Match 'source = "\.\./sibling"'
        [regex]::IsMatch($updated, 'mock_provider "random"') | Should -Be $UsesRandom
    }

    It 'requires manual review when an empty mock is attached to a test module' {
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'delegated.tftest.hcl'
        Set-Content -LiteralPath $testFile -Encoding utf8NoBOM -Value @'
mock_provider "random" {}
run "delegated" {
  module {
    source = "./setup"
  }
}
'@
        $before = [System.IO.File]::ReadAllBytes($testFile)

        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir } {
                param($Root)
                Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                    [pscustomobject]@{ Path = $Root; Profiles = @('root') })
            }
        } | Should -Throw '*still uses a random mock or resource*'
        [System.IO.File]::ReadAllBytes($testFile) | Should -Be $before
    }

    It 'rejects a random provider mapping before removing its mock' {
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'mapped.tftest.hcl'
        Set-Content -LiteralPath $testFile -Encoding utf8NoBOM -Value @'
mock_provider "random" {}
run "mapped" {
  providers = {
    random = random
  }
}
'@
        $before = [System.IO.File]::ReadAllBytes($testFile)

        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir } {
                param($Root)
                Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                    [pscustomobject]@{ Path = $Root; Profiles = @('root') })
            }
        } | Should -Throw '*still uses a random mock or resource*'
        [System.IO.File]::ReadAllBytes($testFile) | Should -Be $before
    }

    It 'rejects a custom random mock before rewriting another unit test' {
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $standard = Join-Path $testDir 'standard.tftest.hcl'
        $custom = Join-Path $testDir 'custom.tftest.hcl'
        Set-Content -LiteralPath $standard -Encoding utf8NoBOM -Value 'mock_provider "random" {}'
        Set-Content -LiteralPath $custom -Encoding utf8NoBOM -Value @'
mock_provider "random" {
  override_resource {
    target = random_string.suffix
  }
}
'@
        $before = [System.IO.File]::ReadAllBytes($standard)

        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleDir } {
                param($Root)
                Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                    [pscustomobject]@{ Path = $Root; Profiles = @('root') })
            }
        } | Should -Throw '*still uses a random mock or resource*'
        [System.IO.File]::ReadAllBytes($standard) | Should -Be $before
        Get-Content -LiteralPath $custom -Raw | Should -Match 'random_string\.suffix'
    }

    It 'rejects custom modtm mocks before changing another test file' {
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $standard = Join-Path $testDir 'standard.tftest.hcl'
        $custom = Join-Path $testDir 'custom.tftest.hcl'
        Set-Content -LiteralPath $standard -Encoding utf8NoBOM -Value 'mock_provider "modtm" {}'
        Set-Content -LiteralPath $custom -Encoding utf8NoBOM -Value @'
mock_provider "modtm" {
  override_resource {
    target = modtm_telemetry.telemetry
  }
}
'@
        $before = Get-Content -LiteralPath $standard -Raw

        {
            InModuleScope 'Avm.Authoring' -Parameters @{ Root = $script:moduleDir } {
                param($Root)
                Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets @(
                    [pscustomobject]@{
                        Path = $Root
                        Profiles = @('root', 'module', 'common')
                    })
            }
        } | Should -Throw '*non-empty modtm mock*'
        Get-Content -LiteralPath $standard -Raw | Should -BeExactly $before
        Get-Content -LiteralPath $custom -Raw | Should -Match 'modtm_telemetry\.telemetry'
    }

    It 'restores rewritten test files after a drift check' {
        $testDir = Join-Path $script:moduleDir 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $testFile = Join-Path $testDir 'telemetry.tftest.hcl'
        Set-Content -LiteralPath $testFile -Encoding utf8NoBOM -Value @'
mock_provider "modtm" {
}
mock_provider "random" {}
run "telemetry" {
  assert {
    condition     = can(modtm_telemetry.telemetry)
    error_message = "Telemetry must be created."
  }
}
'@
        $before = [System.IO.File]::ReadAllBytes($testFile)

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmMapotfConfigDir { "/fake/$ProfileName" }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C -CheckDrift
        }

        $result.Status | Should -Be 'fail'
        $result.Changed | Should -Contain ([System.IO.Path]::Combine('tests', 'unit', 'telemetry.tftest.hcl'))
        [System.IO.File]::ReadAllBytes($testFile) | Should -Be $before
    }

    It 'flags every changed file as a drift Issue under -CheckDrift' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Add-Content -LiteralPath (Join-Path $tfDir 'variables.tf') -Value 'variable "z" {}'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C -CheckDrift
        }
        $result.Status             | Should -Be 'fail'
        @($result.Changed).Count   | Should -Be 1
        @($result.Issues).Count    | Should -Be 1
        $result.Issues[0].File     | Should -Be 'variables.tf'
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].Code     | Should -Be 'avm.tf.mapotf-drift'
    }

    It 'reports pass under -CheckDrift when mapotf changes nothing' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C -CheckDrift
        }
        $result.Status          | Should -Be 'pass'
        @($result.Issues).Count | Should -Be 0
    }

    It 'leaves modified .tf files byte-identical after a drift-mode run' {
        $ctx = $script:context
        $variables = Join-Path $script:moduleDir 'variables.tf'
        $originalBytes = [System.IO.File]::ReadAllBytes($variables)

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList -contains 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Add-Content -LiteralPath (Join-Path $tfDir 'variables.tf') -Value 'variable "z" {}'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C -CheckDrift
        }

        $result.Status | Should -Be 'fail'
        [System.IO.File]::ReadAllBytes($variables) | Should -Be $originalBytes
    }

    It 'removes a .tf file that mapotf created during a drift-mode run' {
        $ctx = $script:context
        $created = Join-Path $script:moduleDir 'generated.tf'

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList -contains 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Set-Content -LiteralPath (Join-Path $tfDir 'generated.tf') -Value 'output "g" {}' -Encoding utf8
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C -CheckDrift
        }

        $result.Status | Should -Be 'fail'
        Test-Path -LiteralPath $created | Should -BeFalse
    }

    It 'recreates a .tf file that mapotf deleted during a drift-mode run' {
        $ctx = $script:context
        $variables = Join-Path $script:moduleDir 'variables.tf'
        $originalBytes = [System.IO.File]::ReadAllBytes($variables)

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList -contains 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Remove-Item -LiteralPath (Join-Path $tfDir 'variables.tf') -Force -ErrorAction SilentlyContinue
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C -CheckDrift
        }

        $result.Status | Should -Be 'fail'
        Test-Path -LiteralPath $variables | Should -BeTrue
        [System.IO.File]::ReadAllBytes($variables) | Should -Be $originalBytes
    }

    It 'restores an example and its <Name> variables.tf when a drift transform fails' -TestCases @(
        @{ Name = 'new'; Existing = $false }
        @{ Name = 'existing'; Existing = $true }
    ) {
        param($Name, $Existing)

        $ctx = $script:context
        $example = Join-Path $ctx.Root 'examples' 'default'
        $null = New-Item -ItemType Directory -Path $example -Force
        $main = Join-Path $example 'main.tf'
        $variables = Join-Path $example 'variables.tf'
        Set-Content -LiteralPath $main -Value 'module "example" { source = "../../" }' -Encoding utf8NoBOM
        if ($Existing) {
            Set-Content -LiteralPath $variables -Value 'variable "enable_telemetry" { default = true }' -Encoding utf8NoBOM
        }
        $before = @{}
        foreach ($file in Get-ChildItem -LiteralPath $ctx.Root -Recurse -Filter '*.tf' -File) {
            $before[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash
        }

        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; Example = $example } {
                param($C, $Example)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name"
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { "/fake/$ProfileName" }
                Mock Invoke-AvmProcess {
                    if ($ArgumentList[0] -eq 'transform' -and $WorkingDirectory -eq $Example) {
                        Set-Content -LiteralPath (Join-Path $Example 'variables.tf') `
                            -Value 'variable "enable_telemetry" { default = false }' -Encoding utf8NoBOM
                        Add-Content -LiteralPath (Join-Path $Example 'main.tf') -Value '# transformed'
                        return [pscustomobject]@{
                            ExitCode = 1
                            StdOut = ''
                            StdErr = 'example transform failed after writing variables.tf'
                        }
                    }
                    [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                Invoke-AvmTerraformTransform -Context $C -CheckDrift
            }
        } | Should -Throw '*example transform failed after writing variables.tf*'

        $restored = @(Get-ChildItem -LiteralPath $ctx.Root -Recurse -Filter '*.tf' -File)
        $restored | Should -HaveCount $before.Count
        foreach ($file in $restored) {
            (Get-FileHash -LiteralPath $file.FullName).Hash | Should -BeExactly $before[$file.FullName]
        }
        Test-Path -LiteralPath $variables | Should -Be $Existing
    }

    It 'still rewrites .tf files when drift mode is off' {
        $ctx = $script:context
        $variables = Join-Path $script:moduleDir 'variables.tf'
        $originalBytes = [System.IO.File]::ReadAllBytes($variables)

        $null = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList -contains 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Add-Content -LiteralPath (Join-Path $tfDir 'variables.tf') -Value 'variable "z" {}'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C
        }

        [System.IO.File]::ReadAllBytes($variables) | Should -Not -Be $originalBytes
    }

    It 'runs the transform with network retry and no local retry loop' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Start-Sleep
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C
        }

        $result.Status | Should -Be 'pass'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter {
                $ArgumentList[0] -eq 'transform' -and $RetryNetworkFailure -and $IgnoreExitCode
            }
            Should -Invoke Start-Sleep -Exactly 0
        }
    }
    It 'throws AvmProcessException when mapotf transform exits non-zero' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/mapotf'
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
                Mock Start-Sleep
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'boom' } }
                Invoke-AvmTerraformTransform -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'transform'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'transform'
            }
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'throws AvmProcessException when a scoped target transform exits non-zero' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/mapotf'
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { "/fake/$ProfileName" }
                Mock Get-AvmTerraformTransformTarget {
                    @(
                        [pscustomobject]@{ Path = $C.Root; Scope = 'root'; Profiles = @('root', 'module', 'common') }
                        [pscustomobject]@{ Path = '/fake/module'; Scope = 'module'; Profiles = @('module', 'common') }
                    )
                }
                Mock Invoke-AvmProcess {
                    $tfDirIndex = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    if ($ArgumentList[0] -eq 'transform' -and $ArgumentList[$tfDirIndex + 1] -eq '/fake/module') {
                        return [pscustomobject]@{ ExitCode = 4; StdOut = ''; StdErr = 'module transform failed' }
                    }
                    [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                Invoke-AvmTerraformTransform -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }

        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'module target'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $tfDirIndex = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                $ArgumentList[0] -eq 'transform' -and $ArgumentList[$tfDirIndex + 1] -eq '/fake/module'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter {
                $ArgumentList[0] -eq 'clean-backup'
            }
        }
    }

    It 'throws AvmProcessException when mapotf clean-backup exits non-zero' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/mapotf'
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
                Mock Invoke-AvmProcess {
                    if ($ArgumentList[0] -eq 'clean-backup') {
                        return [pscustomobject]@{ ExitCode = 3; StdOut = ''; StdErr = 'cleanup failed' }
                    }
                    [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                Invoke-AvmTerraformTransform -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'clean-backup'
    }

    It 'propagates AvmToolException when the mapotf binary is unavailable' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool { throw [AvmToolException]::new('mapotf not installed') }
                Invoke-AvmTerraformTransform -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmToolException'
    }

    It 'propagates AvmConfigurationException when the config bundle cannot be resolved' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/mapotf'
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { throw [AvmConfigurationException]::new('no configs') }
                Invoke-AvmTerraformTransform -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
    }

    It 'returns a skipped envelope and runs mapotf zero times under -WhatIf' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C -WhatIf
        }
        $result.Status         | Should -Be 'skipped'
        $result.FilesProcessed | Should -Be 2

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }
}

Describe 'Set-AvmTelemetryTagLintDirective' {
    BeforeEach {
        $script:lintRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:lintRoot -Force
        $script:lintFile = Join-Path $script:lintRoot 'main.telemetry.tf'
        Set-Content -LiteralPath $script:lintFile -Encoding utf8NoBOM -Value @'
resource "azapi_resource" "other" {
  tags = var.tags
}

resource "azapi_resource" "telemetry" {
  type = "Microsoft.Resources/deployments@2025-04-01"
  # tflint-ignore: avm_azapi_resource_tags_required
  tags = {
    avm_apply_id = plantimestamp()
  }
}
'@
        $script:lintTarget = [pscustomobject]@{ Path = $script:lintRoot; Profiles = @('root') }
    }

    It 'moves the legacy tag directive to the telemetry resource and preserves other resources' {
        $before = Get-Content -LiteralPath $script:lintFile -Raw
        InModuleScope 'Avm.Authoring' -Parameters @{ Target = $script:lintTarget } {
            param($Target)
            Set-AvmTelemetryTagLintDirective -Targets @($Target) -WhatIf
        }
        Get-Content -LiteralPath $script:lintFile -Raw | Should -BeExactly $before

        InModuleScope 'Avm.Authoring' -Parameters @{ Target = $script:lintTarget } {
            param($Target)
            Set-AvmTelemetryTagLintDirective -Targets @($Target)
        }
        $after = Get-Content -LiteralPath $script:lintFile -Raw
        $after | Should -Match '(?m)^# tflint-ignore: avm_azapi_resource_tags_required\r?\nresource "azapi_resource" "telemetry" \{'
        $after | Should -Not -Match '(?m)^  # tflint-ignore: avm_azapi_resource_tags_required'
        $after | Should -Match '(?s)resource "azapi_resource" "other" \{\s*tags\s*=\s*var\.tags'
        @([regex]::Matches($after, 'tflint-ignore: avm_azapi_resource_tags_required')) | Should -HaveCount 1

        InModuleScope 'Avm.Authoring' -Parameters @{ Target = $script:lintTarget } {
            param($Target)
            Set-AvmTelemetryTagLintDirective -Targets @($Target)
        }
        Get-Content -LiteralPath $script:lintFile -Raw | Should -BeExactly $after
    }

    It 'annotates a tagless telemetry deployment' {
        Set-Content -LiteralPath $script:lintFile -Encoding utf8NoBOM -Value @'
resource "azapi_resource" "telemetry" {
  type = "Microsoft.Resources/deployments@2025-04-01"
  body = { properties = { mode = "Incremental" } }
}
'@
        InModuleScope 'Avm.Authoring' -Parameters @{ Target = $script:lintTarget } {
            param($Target)
            Set-AvmTelemetryTagLintDirective -Targets @($Target)
        }
        $content = Get-Content -LiteralPath $script:lintFile -Raw
        $content | Should -Match '(?m)^# tflint-ignore: avm_azapi_resource_tags_required\r?\nresource "azapi_resource" "telemetry" \{'
        $content | Should -Not -Match '(?m)^\s*tags\s*='
    }

    It 'does not silently accept a missing telemetry resource' {
        Set-Content -LiteralPath $script:lintFile -Encoding utf8NoBOM -Value 'resource "azapi_resource" "other" {}'
        $caught = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ Target = $script:lintTarget } {
                param($Target)
                Set-AvmTelemetryTagLintDirective -Targets @($Target)
            }
        }
        catch { $caught = $_.Exception }
        $caught.GetType().Name | Should -Be 'AvmConfigurationException'
        $caught.Message | Should -Match 'Expected one azapi_resource.telemetry block'
    }

    It 'does not require a telemetry resource in a prefix-free helper' {
        Set-Content -LiteralPath $script:lintFile -Encoding utf8NoBOM -Value 'resource "azapi_resource" "other" {}'
        $before = Get-Content -LiteralPath $script:lintFile -Raw
        InModuleScope 'Avm.Authoring' -Parameters @{
            Target = [pscustomobject]@{ Path = $script:lintRoot; Profiles = @('module', 'common') }
        } {
            param($Target)
            Set-AvmTelemetryTagLintDirective -Targets @($Target)
        }
        Get-Content -LiteralPath $script:lintFile -Raw | Should -BeExactly $before
    }
}

Describe 'Get-AvmTerraformTransformTarget' {
    It 'requires correctly cased metadata for <Name>' -TestCases @(
        @{ Name = 'a missing file'; MetadataFile = '' }
        @{ Name = 'a wrong-cased file'; MetadataFile = 'Metadata.JSON' }
    ) {
        param($Name, $MetadataFile)

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root -Force
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value 'output "id" { value = "mock" }'
        if ($MetadataFile) {
            Set-Content -LiteralPath (Join-Path $root $MetadataFile) -Encoding utf8NoBOM -Value $script:terraformMetadata
        }

        $exception = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
                param($R)
                Get-AvmTerraformTransformTarget -Root $R
            }
        }
        catch { $exception = $_.Exception }
        $exception.GetType().Name | Should -Be 'AvmConfigurationException'
        $exception.Message | Should -Match 'requires metadata.json'
    }

    It 'rejects invalid metadata rather than treating the module as telemetry-free' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root -Force
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value 'output "id" { value = "mock" }'
        Set-Content -LiteralPath (Join-Path $root 'metadata.json') -Encoding utf8NoBOM -Value '{"telemetryIdPrefix":'

        $exception = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
                param($R)
                Get-AvmTerraformTransformTarget -Root $R
            }
        }
        catch { $exception = $_.Exception }
        $exception.GetType().Name | Should -Be 'AvmConfigurationException'
        $exception.Message | Should -Match 'Cannot read Terraform module metadata'
    }

    It 'rejects a noncanonical Terraform telemetry prefix: <Prefix>' -TestCases @(
        @{ Prefix = '46d3xtrf.res.mock' }
        @{ Prefix = '46d3xtrf.res.abcdefg' }
        @{ Prefix = '46d3xtrf.res.abcdeF0' }
        @{ Prefix = '46d3xtrf.res.abcdef00' }
    ) {
        param($Prefix)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root -Force
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value 'output "id" { value = "mock" }'
        Set-Content -LiteralPath (Join-Path $root 'metadata.json') -Encoding utf8NoBOM `
            -Value ('{"telemetryIdPrefix":"' + $Prefix + '"}')

        $caught = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
                param($R)
                Get-AvmTerraformTransformTarget -Root $R
            }
        }
        catch { $caught = $_.Exception }
        $caught.GetType().Name | Should -Be 'AvmConfigurationException'
        $caught.Message | Should -Match 'seven lowercase hexadecimal characters'
    }

    It 'does not instrument a valid prefix-free utility root' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root -Force
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value 'output "id" { value = "mock" }'
        Set-Content -LiteralPath (Join-Path $root 'metadata.json') -Encoding utf8NoBOM -Value @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Mock utility",
  "moduleDescription": "Utility without telemetry.",
  "canonicalType": "naming",
  "owners": []
}
'@

        $targets = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            @(Get-AvmTerraformTransformTarget -Root $R)
        }
        $targets | Should -HaveCount 1
        $targets[0].Profiles | Should -Be @('module', 'common')
    }

    It 'returns scoped root, nested module, and direct example targets' {
        $root = Join-Path $TestDrive 'repo'
        $direct = Join-Path $root 'modules' 'direct'
        $nested = Join-Path $root 'modules' 'group' 'nested'
        $notModule = Join-Path $root 'modules' 'group' 'examples' 'default'
        $example = Join-Path $root 'examples' 'default'
        $testWrapper = Join-Path $root 'tests' 'wrapper'
        $childWrapper = Join-Path $direct 'tests' 'wrapper'
        $helperWrapper = Join-Path $nested 'tests' 'wrapper'
        New-Item -ItemType Directory -Path $direct, $nested, $notModule, $example, $testWrapper, $childWrapper, $helperWrapper -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'metadata.json') -Value $script:terraformMetadata -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $direct 'main.tf') -Value 'output "direct" { value = true }' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $direct 'metadata.json') -Value $script:terraformMetadata -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $nested 'terraform.tf') -Value 'terraform {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $nested 'metadata.json') -Value '{"canonicalType":"helper"}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $notModule 'main.tf') -Value 'locals {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $example 'main.tf') -Value 'locals {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $testWrapper 'terraform.tf') -Value 'terraform {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $childWrapper 'terraform.tf') -Value 'terraform {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $helperWrapper 'terraform.tf') -Value 'terraform {}' -Encoding utf8NoBOM

        $targets = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            @(Get-AvmTerraformTransformTarget -Root $R)
        }

        $targets | Should -HaveCount 6
        ($targets | Where-Object Path -eq $root).Profiles | Should -Be @('root', 'module', 'common')
        ($targets | Where-Object Path -eq $direct).Profiles | Should -Be @('root', 'module', 'common')
        ($targets | Where-Object Path -eq $nested).Profiles | Should -Be @('module', 'common')
        ($targets | Where-Object Path -eq $example).Profiles | Should -Be @('example', 'provider-cleanup', 'common')
        ($targets | Where-Object Path -eq $testWrapper).Profiles | Should -Be @('provider-cleanup', 'test')
        ($targets | Where-Object Path -eq $childWrapper).Profiles | Should -Be @('provider-cleanup', 'test')
        @($targets.Path) | Should -Not -Contain $notModule
        @($targets.Path) | Should -Not -Contain $helperWrapper
    }
}

Describe 'Resolve-AvmMapotfConfigDir' {
    BeforeAll {
        function script:New-AvmCfgBundle {
            param(
                [string] $Path,
                [string] $Profile = 'common',
                [string] $FileName = 'sample.mptf.hcl'
            )
            $profilePath = Join-Path $Path $Profile
            New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $profilePath $FileName) -Value 'transform {}' -Encoding utf8
            return $profilePath
        }
    }

    BeforeEach {
        $script:savedConfigDir = $env:AVM_MPTF_CONFIG_DIR
    }

    AfterEach {
        if ($null -eq $script:savedConfigDir) {
            Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_MPTF_CONFIG_DIR = $script:savedConfigDir
        }
    }

    It 'prefers the AVM_MPTF_CONFIG_DIR <Profile> override over the consumer and packaged bundles' -TestCases @(
        @{ Profile = 'common' }
        @{ Profile = 'example' }
    ) {
        param($Profile)

        $override = script:New-AvmCfgBundle -Profile $Profile -Path (Join-Path $TestDrive ("cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)))
        $root = Join-Path $TestDrive ("repo-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        script:New-AvmCfgBundle -Profile $Profile -Path ([System.IO.Path]::Combine($root, 'config', 'mapotf')) -FileName 'consumer.mptf.hcl' | Out-Null
        $env:AVM_MPTF_CONFIG_DIR = Split-Path -Parent $override

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root; Profile = $Profile } {
            param($R, $Profile)
            Resolve-AvmMapotfConfigDir -Root $R -ProfileName $Profile
        }
        $resolved | Should -Be ((Resolve-Path -LiteralPath $override).ProviderPath)
    }

    It 'prefers the consumer config/mapotf <Profile> profile over the packaged profile' -TestCases @(
        @{ Profile = 'common' }
        @{ Profile = 'example' }
    ) {
        param($Profile)

        Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        $root = Join-Path $TestDrive ("repo-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $consumer = script:New-AvmCfgBundle -Profile $Profile -Path ([System.IO.Path]::Combine($root, 'config', 'mapotf')) -FileName 'consumer.mptf.hcl'

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root; Profile = $Profile } {
            param($R, $Profile)
            Resolve-AvmMapotfConfigDir -Root $R -ProfileName $Profile
        }
        $resolved | Should -Be ((Resolve-Path -LiteralPath $consumer).ProviderPath)
    }

    It 'skips an empty AVM_MPTF_CONFIG_DIR <Profile> profile and uses the consumer profile' -TestCases @(
        @{ Profile = 'common' }
        @{ Profile = 'example' }
    ) {
        param($Profile)

        $emptyOverride = Join-Path $TestDrive ("empty-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $emptyOverride -Force | Out-Null
        $root = Join-Path $TestDrive ("repo-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $consumer = script:New-AvmCfgBundle -Profile $Profile -Path ([System.IO.Path]::Combine($root, 'config', 'mapotf')) -FileName 'consumer.mptf.hcl'
        $env:AVM_MPTF_CONFIG_DIR = $emptyOverride

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root; Profile = $Profile } {
            param($R, $Profile)
            Resolve-AvmMapotfConfigDir -Root $R -ProfileName $Profile
        }
        $resolved | Should -Be ((Resolve-Path -LiteralPath $consumer).ProviderPath)
    }

    It 'falls back to the packaged profile when no override or consumer profile exists' {
        Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        $root = Join-Path $TestDrive ("bare-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Resolve-AvmMapotfConfigDir -Root $R -ProfileName common
        }
        $resolved | Should -Not -BeNullOrEmpty
        (Split-Path -Leaf $resolved) | Should -Be 'common'
        $resolved | Should -Match ([regex]::Escape([System.IO.Path]::Combine('Resources', 'mapotf', 'common')))
        @(Get-ChildItem -LiteralPath $resolved -Filter '*.mptf.hcl' -File).Count | Should -BeGreaterThan 0
    }

    It 'resolves the packaged example telemetry profile without an override' {
        Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        $root = Join-Path $TestDrive ("bare-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Resolve-AvmMapotfConfigDir -Root $R -ProfileName example
        }
        $resolved | Should -Not -BeNullOrEmpty
        $resolved | Should -BeExactly (Join-Path $script:moduleRoot 'Resources' 'mapotf' 'example')
        (Join-Path $resolved 'disable_telemetry.mptf.hcl') | Should -Exist
    }

    It 'keeps a consumer test profile optional after sharing provider cleanup' {
        Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        $root = Join-Path $TestDrive ("repo-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $without = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Resolve-AvmMapotfConfigDir -Root $R -ProfileName test -Optional
        }
        $without | Should -BeNullOrEmpty

        $consumer = script:New-AvmCfgBundle -Profile 'test' -Path (Join-Path $root 'config' 'mapotf')
        $with = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Resolve-AvmMapotfConfigDir -Root $R -ProfileName test -Optional
        }
        $with | Should -BeExactly (Resolve-Path -LiteralPath $consumer).ProviderPath
    }

    It 'returns null for an absent optional profile' {
        Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        $root = Join-Path $TestDrive ("bare-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Mock Test-Path { $false }
            Resolve-AvmMapotfConfigDir -Root $R -ProfileName example -Optional
        }
        $resolved | Should -BeNullOrEmpty
    }
}
