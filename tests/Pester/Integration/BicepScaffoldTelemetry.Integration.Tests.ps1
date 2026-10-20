#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: Bicep scaffold telemetry' -Tag Integration {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' `
                    -AdditionalChildPath '..', '..')).ProviderPath
        . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Import-AvmTestModule.ps1') `
            -SourceManifest (Join-Path -Path $script:repoRoot -ChildPath 'src' `
                -AdditionalChildPath 'Avm.Authoring', 'Avm.Authoring.psd1')
        $script:scaffoldEnvironment = @{}
        foreach ($name in @('AVM_OFFLINE', 'AVM_NO_AUTO_INSTALL')) {
            $script:scaffoldEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
            [System.Environment]::SetEnvironmentVariable($name, '1', 'Process')
        }
        $script:bicepTool = InModuleScope 'Avm.Authoring' { Resolve-AvmTool -Name bicep }
        $script:bicepTool.Version | Should -BeExactly '0.48.1'
        $schemaPath = Join-Path -Path (Get-Module -Name Avm.Authoring).ModuleBase -ChildPath 'Resources' `
            -AdditionalChildPath 'Schemas', 'v1', 'avm-module-metadata.schema.json'
        $script:metadataSchemaId = (Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json).'$id'

        function Test-CompiledScaffoldTelemetry {
            param([Parameter(Mandatory)][string] $Path)

            InModuleScope 'Avm.Authoring' -Parameters @{ P = $Path; Tool = $script:bicepTool.Path } {
                param($P, $Tool)
                $sourcePath = Join-Path $P 'main.bicep'
                $result = Invoke-AvmProcess -FilePath $Tool `
                    -ArgumentList @('build', '--stdout', $sourcePath, '--no-restore')
                $result.ExitCode | Should -Be 0
                $result.StdOut | Should -Not -BeNullOrEmpty
                $template = $result.StdOut | ConvertFrom-Json -AsHashtable
                $template['resources'].Count | Should -BeGreaterThan 0
                $scope = Get-AvmBicepConventionScope -Path $P
                $compiled = [pscustomobject]@{
                    Path = $sourcePath; Scope = $scope; Template = $template; Json = $result.StdOut
                }
                $convention = @{
                    Root                   = $P
                    CompiledInputs         = @(Get-AvmBicepCompiledConventionInput -Module $compiled)
                    NativeCompiledExpected = 0
                }
                $suite = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Resources' 'bicep' 'conventions' 'Compiled.Tests.ps1'
                $summary = Invoke-AvmBicepPesterSuite -Files @($suite) -WorkingDirectory $P `
                    -Mode Convention -ConventionData $convention -EnvVars @{} -InProcess
                $convention.NativeCompiledExpected | Should -BeGreaterThan 11
                $summary.Total | Should -Be $convention.NativeCompiledExpected
                ($summary.Passed + $summary.Failed) | Should -Be $convention.NativeCompiledExpected
                @($summary.Issues | Where-Object { $_.Code -like 'avm.bicep.pester-*' }).Count |
                    Should -Be 0 -Because (@($summary.Issues | ForEach-Object { $_.Message }) -join '; ')
                @($summary.Issues | Where-Object { $_.Code -like 'avm.bicep.telemetry-*' })
            }
        }
    }

    AfterAll {
        foreach ($name in $script:scaffoldEnvironment.Keys) {
            $value = $script:scaffoldEnvironment[$name]
            if ($null -eq $value) {
                $value = [NullString]::Value
            }
            [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
        Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:scaffoldRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:scaffoldPath = Join-Path -Path $script:scaffoldRoot -ChildPath 'avm' `
            -AdditionalChildPath 'res', 'mock', 'scaffold'
        $null = New-Item -ItemType Directory -Path $script:scaffoldPath -Force
        $metadata = [ordered]@{
            '$schema'         = $script:metadataSchemaId
            moduleDisplayName = 'Mock scaffold'
            moduleDescription = 'Deploys a mock scaffold.'
            canonicalType     = 'Microsoft.Storage/storageAccounts'
            owners            = @()
            telemetryIdPrefix = '46d3xbcp.res.abc1234'
        }
        [System.IO.File]::WriteAllText((Join-Path $script:scaffoldPath 'metadata.json'),
            ($metadata | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
        $result = Initialize-AvmModule -Path $script:scaffoldPath -Ecosystem bicep `
            -ModuleType resource -SkipModuleVersionCheck -Confirm:$false
        $result.Status | Should -BeExactly 'pass'
        $result.Changed | Should -BeTrue
        $script:scaffoldSourcePath = Join-Path $script:scaffoldPath 'main.bicep'
        $script:scaffoldSource = [System.IO.File]::ReadAllText($script:scaffoldSourcePath)
    }

    It 'compiles the actual generated canonical scaffold and validates its telemetry' {
        $script:scaffoldSource | Should -Match 'var telemetryIdPrefix = loadJsonContent'
        $script:scaffoldSource | Should -Match ([regex]::Escape(
                "Optional. Enable/Disable usage telemetry for module."))
        $issues = @(Test-CompiledScaffoldTelemetry -Path $script:scaffoldPath)
        $issues.Count | Should -Be 0 -Because ($issues | ConvertTo-Json -Compress -Depth 6)
    }

    It 'still compiles and accepts the byte-preserved legacy reader and description' {
        $source = $script:scaffoldSource.Replace(
            "var telemetryIdPrefix = loadJsonContent('metadata.json', 'telemetryIdPrefix')",
            "var avmTelemetryIdPrefix = loadJsonContent('metadata.json', '$.telemetryIdPrefix')")
        $source = $source.Replace('${telemetryIdPrefix}', '${avmTelemetryIdPrefix}').Replace(
            'Optional. Enable/Disable usage telemetry for module.',
            'Optional. Enable/disable usage telemetry for this module.')
        [System.IO.File]::WriteAllText($script:scaffoldSourcePath, $source, [System.Text.UTF8Encoding]::new($false))
        $hash = (Get-FileHash -LiteralPath $script:scaffoldSourcePath -Algorithm SHA256).Hash
        $issues = @(Test-CompiledScaffoldTelemetry -Path $script:scaffoldPath)
        $issues.Count | Should -Be 0 -Because ($issues | ConvertTo-Json -Compress -Depth 6)
        (Get-FileHash -LiteralPath $script:scaffoldSourcePath -Algorithm SHA256).Hash | Should -BeExactly $hash
    }

    It 'rejects real compiled invalid telemetry: <Case>' -ForEach @(
        @{ Case = 'mixed description'; Code = 'avm.bicep.telemetry-parameter' }
        @{ Case = 'hardcoded prefix'; Code = 'avm.bicep.telemetry-source' }
        @{ Case = 'non-prefix-first name'; Code = 'avm.bicep.telemetry-name' }
    ) {
        $source = switch ($Case) {
            'mixed description' {
                $script:scaffoldSource.Replace('Optional. Enable/Disable usage telemetry for module.',
                    'Optional. Enable/disable usage telemetry for this module.')
            }
            'hardcoded prefix' {
                $script:scaffoldSource.Replace(
                    "var telemetryIdPrefix = loadJsonContent('metadata.json', 'telemetryIdPrefix')",
                    "var telemetryIdPrefix = '46d3xbcp.res.abc1234'")
            }
            'non-prefix-first name' {
                $script:scaffoldSource.Replace("name: '`${telemetryIdPrefix}.", "name: 'wrong.`${telemetryIdPrefix}.")
            }
        }
        $source | Should -Not -BeExactly $script:scaffoldSource
        [System.IO.File]::WriteAllText($script:scaffoldSourcePath, $source, [System.Text.UTF8Encoding]::new($false))
        $issues = @(Test-CompiledScaffoldTelemetry -Path $script:scaffoldPath)
        $issues.Code | Should -Contain $Code
    }
}
