#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).ProviderPath
    $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
    $script:fixtureRoot = Join-Path $script:repoRoot 'tests' 'fixtures' 'bicep-convention'
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep static convention checks' -Tag 'Component' {
    BeforeEach {
        $script:workingRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:fixtureRoot -Destination $script:workingRoot -Recurse
        $script:modulePath = Join-Path $script:workingRoot 'avm' 'res' 'mock' 'widget'
        $e2e = Join-Path $script:workingRoot 'compiled-e2e.json'
        $childCompiled = Join-Path $script:fixtureRoot 'avm' 'res' 'mock' 'widget' 'child' 'main.json'
        InModuleScope 'Avm.Authoring' -Parameters @{
            Fixture = $e2e; ChildCompiled = $childCompiled
        } {
            param($Fixture, $ChildCompiled)
            $script:compiledE2E = $Fixture
            $script:originalChildCompiled = $ChildCompiled
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'fixture'; Path = 'mock-bicep'; Source = 'fixture' }
            }
            Mock Invoke-AvmProcess {
                $source = $ArgumentList[2]
                $compiled = if ($source -match '[\\/]modules[\\/].*[\\/]main\.bicep$') {
                    $script:originalChildCompiled
                }
                elseif ($source.EndsWith('main.test.bicep', [System.StringComparison]::Ordinal)) {
                    $script:compiledE2E
                }
                else {
                    [System.IO.Path]::ChangeExtension($source, '.json')
                }
                if (-not [System.IO.File]::Exists($compiled)) {
                    $compiled = $script:originalChildCompiled
                }
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = [System.IO.File]::ReadAllText($compiled)
                    StdErr   = ''
                }
            }
        }
    }

    It 'checks the complete root and child fixture and reports only the known coverage gap' {
        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck

        $result.Engine | Should -Be 'bicep'
        $result.Status | Should -Be 'fail'
        $result.ScopesChecked | Should -Be 2
        $result.CompiledFiles | Should -Be 5
        $result.CompilerSource | Should -Be 'fixture'
        $result.UncoveredFamilies.Count | Should -Be 5
        $result.UncoveredFamilies | Should -Contain 'registry-literal telemetry syntax and description parity for scaffolded modules'
        $result.UncoveredFamilies | Should -Not -Contain 'checked-in main.json drift for children under modules/'
        $result.Issues.Count | Should -Be 1
        $result.Issues[0].Code | Should -Be 'avm.bicep.convention-incomplete'
        $result.Issues[0].Severity | Should -Be 'error'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 5 -ParameterFilter {
                $ArgumentList[0] -eq 'build' -and $ArgumentList[1] -eq '--stdout'
            }
        }
    }

    It 'names root, child, and e2e compilation failures without skipping the other sources' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmProcess {
                $source = $ArgumentList[2]
                if ($source -match '[\\/]child[\\/]main\.bicep$' -or
                    $source -match '[\\/]waf-aligned[\\/]main\.test\.bicep$') {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'BCP999: invalid source' }
                }
                $compiled = if ($source.EndsWith('main.test.bicep', [System.StringComparison]::Ordinal)) {
                    $script:compiledE2E
                }
                else {
                    [System.IO.Path]::ChangeExtension($source, '.json')
                }
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = [System.IO.File]::ReadAllText($compiled)
                    StdErr   = ''
                }
            }
        }

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $failed = @($result.Issues | Where-Object Code -eq 'avm.bicep.compile')
        $result.CompiledFiles | Should -Be 3
        $failed.Count | Should -Be 2
        $failed.File | Should -Contain 'child/main.bicep'
        $failed.File | Should -Contain 'tests/e2e/waf-aligned/main.test.bicep'
        $failed.Message | Should -Match 'BCP999'
        $result.Issues.Code | Should -Contain 'avm.bicep.convention-incomplete'
    }

    It 'fails closed with a named issue when the pinned compiler is unavailable' {
        InModuleScope 'Avm.Authoring' {
            Mock Resolve-AvmTool {
                throw [AvmToolException]::new('Pinned Bicep CLI is unavailable.', 'AVM1014')
            }
        }

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.CompiledFiles | Should -Be 0
        $result.CompilerSource | Should -Be 'not-run'
        $result.Issues.Code | Should -Contain 'avm.bicep.compiler-unavailable'
        $result.Status | Should -Be 'fail'
        InModuleScope 'Avm.Authoring' { Should -Invoke Invoke-AvmProcess -Exactly 0 }
    }

    It 'reports invalid compiled schema and metadata on both root and child source paths' {
        $rootJson = Join-Path $script:modulePath 'main.json'
        $childJson = Join-Path $script:modulePath 'child' 'main.json'
        $rootTemplate = [System.IO.File]::ReadAllText($rootJson) | ConvertFrom-Json -AsHashtable
        $rootTemplate['$schema'] = 'http://schema.management.azure.com/obsolete'
        $childTemplate = [System.IO.File]::ReadAllText($childJson) | ConvertFrom-Json -AsHashtable
        $childTemplate['metadata']['description'] = ''
        $rootTemplate | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $rootJson -Encoding utf8NoBOM
        $childTemplate | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $childJson -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        @($result.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.compiled-schema' -and $_.File -eq 'main.bicep'
            }).Count | Should -Be 1
        $result.Issues.Code | Should -Contain 'avm.bicep.compiled-schema-https'
        @($result.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.compiled-metadata-description' -and
                $_.File -eq 'child/main.bicep'
            }).Count | Should -Be 1
    }

    It 'detects telemetry, output, and metadata-prefix drift in a versioned module' {
        $rootJson = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($rootJson) | ConvertFrom-Json -AsHashtable
        $template['parameters']['enableTelemetry']['defaultValue'] = $false
        $template['variables']['$fxv#0'] = 'incorrect-prefix'
        $template['resources'][1]['condition'] = '[false()]'
        $template['resources'][1]['properties']['template']['outputs']['telemetry']['value'] = 'incorrect'
        $null = $template['outputs'].Remove('resourceId')
        $template['outputs']['location']['value'] = "[parameters('name')]"
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $rootJson -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-parameter'
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-condition'
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-output'
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-prefix'
        $result.Issues.Code | Should -Contain 'avm.bicep.output-resourceId'
        $result.Issues.Code | Should -Contain 'avm.bicep.output-location'
    }

    It 'requires a deployment, location default, standard variable names, and resource-group output' {
        $rootJson = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($rootJson) | ConvertFrom-Json -AsHashtable
        $template['resources'] = @($template['resources'][0])
        $template['variables']['Bad-name'] = 'invalid'
        $template['parameters']['location'] = @{
            type = 'string'; defaultValue = 'eastus'
            metadata = @{ description = 'Optional. Deployment location.' }
        }
        $template['outputs']['Bad_name'] = @{
            type = 'string'; metadata = @{ description = 'lowercase output' }; value = 'invalid'
        }
        $null = $template['outputs'].Remove('resourceGroupName')
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $rootJson -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-deployment'
        $result.Issues.Code | Should -Contain 'avm.bicep.parameter-location'
        $result.Issues.Code | Should -Contain 'avm.bicep.variable-name'
        $result.Issues.Code | Should -Contain 'avm.bicep.output-name'
        $result.Issues.Code | Should -Contain 'avm.bicep.output-description'
        $result.Issues.Code | Should -Contain 'avm.bicep.output-resource-group'
    }

    It 'checks compiled parameter and UDT violations in a child module' {
        $childJson = Join-Path $script:modulePath 'child' 'main.json'
        $template = [System.IO.File]::ReadAllText($childJson) | ConvertFrom-Json -AsHashtable
        $template['parameters'] = [ordered]@{
            'Bad_name' = @{
                type = 'string'; metadata = @{ description = 'Missing punctuation' }
            }
        }
        $template['definitions'] = [ordered]@{
            Bad_type = @{ type = 'array'; nullable = $true }
        }
        $template['outputs'] = [ordered]@{
            'Bad_output' = @{
                type = 'string'; metadata = @{ description = 'lowercase' }; value = 'invalid'
            }
        }
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $childJson -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        foreach ($code in @('avm.bicep.parameter-name', 'avm.bicep.parameter-description',
                'avm.bicep.udt-array', 'avm.bicep.udt-nullable', 'avm.bicep.udt-name',
                'avm.bicep.output-name', 'avm.bicep.output-description')) {
            @($result.Issues | Where-Object {
                    $_.Code -eq $code -and $_.File -eq 'child/main.bicep'
                }).Count | Should -BeGreaterThan 0
        }
    }

    It 'raises untyped-object findings from warning to error at version 1' {
        $rootJson = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($rootJson) | ConvertFrom-Json -AsHashtable
        $template['parameters']['options'] = @{
            type = 'object'; defaultValue = @{}
            metadata = @{ description = 'Optional. Widget options.' }
        }
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $rootJson -Encoding utf8NoBOM

        $before = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        @($before.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.parameter-untyped-object' -and $_.Severity -eq 'warning'
            }).Count | Should -Be 1

        Set-Content -LiteralPath (Join-Path $script:modulePath 'version.json') `
            -Value '{"version":"1.0"}' -Encoding utf8NoBOM
        $after = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        @($after.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.parameter-untyped-object' -and $_.Severity -eq 'error'
            }).Count | Should -Be 1
    }

    It 'rejects hardcoded source telemetry and missing metadata even when the compiled template has a prefix' {
        $sourcePath = Join-Path $script:modulePath 'main.bicep'
        $source = [System.IO.File]::ReadAllText($sourcePath)
        [System.IO.File]::WriteAllText($sourcePath, $source.Replace(
                "var telemetryIdPrefix = loadJsonContent('metadata.json', 'telemetryIdPrefix')",
                "var telemetryIdPrefix = '46d3xbcp.res.mock.widget.abc1234'"))
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'metadata.json')

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-source'
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-literal'
        @($result.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.telemetry-metadata' -and $_.File -eq 'metadata.json'
            }).Count | Should -Be 1
    }

    It 'accepts the shipped scaffold telemetry declaration and description as a distinct supported form' {
        $scaffold = Join-Path $script:workingRoot 'avm' 'res' 'mock' 'scaffold'
        New-Item -ItemType Directory -Path $scaffold -Force | Out-Null
        $sourcePath = Join-Path $scaffold 'main.bicep'
        $scaffoldTemplate = Join-Path $script:moduleRoot 'Resources' 'Scaffolds' 'Bicep' 'main.bicep'
        $source = [System.IO.File]::ReadAllText($scaffoldTemplate)
        $source = $source.Replace('<Add module name>', 'Mock scaffold')
        $source = $source.Replace('<Add description>', 'Deploys a mock scaffold.')
        [System.IO.File]::WriteAllText($sourcePath, $source)
        foreach ($name in @('metadata.json', 'version.json')) {
            Copy-Item -LiteralPath (Join-Path $script:modulePath $name) -Destination (Join-Path $scaffold $name)
        }
        $rootJson = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($rootJson) | ConvertFrom-Json -AsHashtable
        $template['parameters']['enableTelemetry']['metadata']['description'] = `
            'Optional. Enable/disable usage telemetry for this module.'
        $template['variables']['avmTelemetryIdPrefix'] = $template['variables']['telemetryIdPrefix']
        $null = $template['variables'].Remove('telemetryIdPrefix')
        $template['resources'] = @($template['resources'][1])
        $template['resources'][0]['name'] = "[format('{0}.mock', variables('avmTelemetryIdPrefix'))]"
        $scope = InModuleScope 'Avm.Authoring' -Parameters @{ P = $scaffold } {
            param($P)
            Get-AvmBicepConventionScope -Path $P
        }

        $issues = @(InModuleScope 'Avm.Authoring' -Parameters @{
            T = $template; S = $scope; P = $sourcePath; R = $script:workingRoot
        } {
            param($T, $S, $P, $R)
            $resources = @(Get-AvmBicepConventionResource -Template $T)
            Test-AvmBicepConventionCompiledTelemetry -Root $R -Scope $S `
                -Template $T -SourcePath $P -Resources $resources
        })
        $issues.Count | Should -Be 0
    }

    It 'validates symbolic child deployment telemetry forwarding without requiring a false child variable in patterns' {
        $rootJson = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($rootJson) | ConvertFrom-Json -AsHashtable
        $child = [ordered]@{
            type       = 'Microsoft.Resources/deployments'
            name       = 'child'
            properties = [ordered]@{
                template   = @{ parameters = @{ enableTelemetry = @{ type = 'bool' } } }
                parameters = @{ enableTelemetry = @{ value = "[parameters('enableTelemetry')]" } }
            }
        }
        $template['languageVersion'] = '2.0'
        $template['resources'] = [ordered]@{
            widget    = $template['resources'][0]
            telemetry = $template['resources'][1]
            child     = $child
        }
        $template['outputs']['location']['value'] = "[reference('widget', '2023-05-01', 'full').location]"
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $rootJson -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-child-variable'
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-child-forwarding'
        $result.Issues.Code | Should -Not -Contain 'avm.bicep.output-location'

        $scope = [pscustomobject]@{
            Path               = $script:modulePath
            ModuleType         = 'ptn'
            ModuleRelativePath = 'avm/ptn/mock/widget'
            IsTopLevel         = $true
            ScopeDirectories   = @()
        }
        $patternIssues = InModuleScope 'Avm.Authoring' -Parameters @{
            T = $template; S = $scope; R = $script:modulePath
        } {
            param($T, $S, $R)
            $resources = @(Get-AvmBicepConventionResource -Template $T)
            @(Test-AvmBicepConventionCompiledTelemetry -Root $R -Scope $S `
                    -Template $T -SourcePath (Join-Path $R 'main.bicep') -Resources $resources)
        }
        @($patternIssues | Where-Object { $_.Code -like 'avm.bicep.telemetry-child-*' }).Count |
            Should -Be 0
    }

    It 'reports invalid compiled e2e JSON rather than falling back to source-only deployment checks' {
        [System.IO.File]::WriteAllText((Join-Path $script:workingRoot 'compiled-e2e.json'), '{invalid')

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $compiledErrors = @($result.Issues | Where-Object Code -eq 'avm.bicep.compile')
        $compiledErrors.Count | Should -Be 3
        $result.CompiledFiles | Should -Be 2
        @($compiledErrors | Where-Object { $_.File -match '^tests/e2e/[^/]+/main\.test\.bicep$' }).Count |
            Should -Be 3
        $result.Issues.Code | Should -Contain 'avm.bicep.convention-incomplete'
    }

    It 'accepts both CRLF and LF line endings in test sources' {
        $testPath = Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep'
        $source = [System.IO.File]::ReadAllText($testPath)
        [System.IO.File]::WriteAllText($testPath, $source.Replace("`r`n", "`n").Replace("`n", "`r`n"))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        @($result.Issues | Where-Object Code -ne 'avm.bicep.convention-incomplete').Count |
            Should -Be 0
    }

    It 'does not report a false success when the module does not have a registry layout' {
        $outside = Join-Path $TestDrive 'standalone'
        New-Item -ItemType Directory -Path $outside | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'main.bicep') -Value "metadata name = 'Standalone'"

        $result = Invoke-AvmCheckConvention -Path $outside -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.scope'
        $result.Issues.Code | Should -Contain 'avm.bicep.convention-incomplete'
    }

    It 'requires a top-level main.bicep even when only metadata and another Bicep file remain' {
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'main.bicep')
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'main.json')
        Set-Content -LiteralPath (Join-Path $script:modulePath 'metadata.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:modulePath 'helper.bicep') -Value "metadata name = 'Helper'"

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.required-source'
    }

    It 'checks nested Bicep modules under a modules directory' {
        $child = Join-Path $script:modulePath 'modules' 'project'
        New-Item -ItemType Directory -Path $child -Force | Out-Null
        foreach ($name in @('main.bicep', 'main.json', 'README.md')) {
            Copy-Item -LiteralPath (Join-Path $script:modulePath 'child' $name) `
                -Destination (Join-Path $child $name)
        }

        $passing = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $passing.ScopesChecked | Should -Be 3
        @($passing.Issues | Where-Object Code -ne 'avm.bicep.convention-incomplete').Count |
            Should -Be 0

        Remove-Item -LiteralPath (Join-Path $child 'README.md')
        $failing = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        @($failing.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.required-file' -and $_.File -eq 'modules/project/README.md'
            }).Count | Should -Be 1
    }

    It 'compares nested modules checked-in ARM JSON and names stale or missing artifacts without rewriting them' {
        $child = Join-Path $script:modulePath 'modules' 'project'
        New-Item -ItemType Directory -Path $child -Force | Out-Null
        foreach ($name in @('main.bicep', 'main.json', 'README.md')) {
            Copy-Item -LiteralPath (Join-Path $script:modulePath 'child' $name) `
                -Destination (Join-Path $child $name)
        }
        $artifact = Join-Path $child 'main.json'
        $passing = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $passing.ScopesChecked | Should -Be 3
        @($passing.Issues | Where-Object Code -ne 'avm.bicep.convention-incomplete').Count |
            Should -Be 0

        $original = [System.IO.File]::ReadAllText($artifact)
        [System.IO.File]::WriteAllText($artifact, "$original`n", [System.Text.UTF8Encoding]::new($false))
        $before = [System.IO.File]::ReadAllBytes($artifact)
        $stale = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $staleIssues = @($stale.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.json-stale' -and $_.File -eq 'modules/project/main.json'
            })
        $staleIssues.Count | Should -Be 1
        $staleIssues[0].Message | Should -Match 'avm pre-commit'
        [System.IO.File]::ReadAllBytes($artifact) | Should -Be $before

        Remove-Item -LiteralPath $artifact
        $missing = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        @($missing.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.json-missing' -and $_.File -eq 'modules/project/main.json'
            }).Count | Should -Be 1
        Test-Path -LiteralPath $artifact | Should -BeFalse
    }

    It 'does not require compiled JSON for a source-less metadata-only modules child' {
        $child = Join-Path $script:modulePath 'modules' 'proposed'
        New-Item -ItemType Directory -Path $child -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $child 'metadata.json'), '{}', [System.Text.UTF8Encoding]::new($false))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.ScopesChecked | Should -Be 3
        $result.CompiledFiles | Should -Be 5
        @($result.Issues | Where-Object Code -ne 'avm.bicep.convention-incomplete').Count |
            Should -Be 0
    }

    It 'identifies missing files and incorrect README casing in root and child scopes' {
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'child' 'main.json')
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'README.md')
        Set-Content -LiteralPath (Join-Path $script:modulePath 'Readme.md') -Value '# Wrong case'

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $missing = @($result.Issues | Where-Object Code -eq 'avm.bicep.required-file')

        $missing.Count | Should -Be 2
        $missing.File | Should -Contain 'README.md'
        $missing.File | Should -Contain 'child/main.json'
    }

    It 'requires a version file for a single-scope root and a changelog for a versioned child' {
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'version.json')
        Set-Content -LiteralPath (Join-Path $script:modulePath 'child' 'version.json') -Value '{"version":"0.1"}'

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.version-missing'
        $result.Issues.Code | Should -Contain 'avm.bicep.changelog-missing'
    }

    It 'reports invalid version values and malformed changelog sections with file positions' {
        Set-Content -LiteralPath (Join-Path $script:modulePath 'version.json') -Value '{"version":"1.0.0"}'
        $changelogPath = Join-Path $script:modulePath 'CHANGELOG.md'
        $changelog = [System.IO.File]::ReadAllText($changelogPath)
        [System.IO.File]::WriteAllText(
            $changelogPath,
            $changelog.Replace('### Breaking Changes', "### Changes`n`n- Duplicate`n`n### Breaking Changes"))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.version-format'
        $result.Issues.Code | Should -Contain 'avm.bicep.changelog-section'
        @($result.Issues | Where-Object Code -eq 'avm.bicep.changelog-section').Line[0] |
            Should -BeGreaterThan 1
    }

    It 'detects a nonzero major version and an incorrect changelog link' {
        Set-Content -LiteralPath (Join-Path $script:modulePath 'version.json') -Value '{"version":"1.0"}'
        $changelogPath = Join-Path $script:modulePath 'CHANGELOG.md'
        $changelog = [System.IO.File]::ReadAllText($changelogPath)
        [System.IO.File]::WriteAllText($changelogPath, $changelog.Replace('widget/CHANGELOG.md', 'widget/MISSING.md'))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.version-major'
        $result.Issues.Code | Should -Contain 'avm.bicep.changelog-header'
    }

    It 'requires a waf-aligned folder and a test source file in every e2e directory' {
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'tests' 'e2e' 'waf-aligned') -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep')

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.waf-test-missing'
        $result.Issues.Code | Should -Contain 'avm.bicep.test-file-missing'
    }

    It 'blocks skipping required resource tests and requires a reason for permitted exclusions' {
        Set-Content -LiteralPath (Join-Path $script:modulePath 'tests' 'e2e' 'defaults' '.e2eignore') -Value 'Not allowed'
        Set-Content -LiteralPath (Join-Path $script:modulePath 'tests' 'e2e' 'max' '.e2eignore') -Value ''

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.e2eignore-required-test'
        $result.Issues.Code | Should -Contain 'avm.bicep.e2eignore-reason'
    }

    It 'reports source errors instead of accepting commented-out test metadata or namePrefix' {
        $testPath = Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep'
        $source = [System.IO.File]::ReadAllText($testPath)
        [System.IO.File]::WriteAllText(
            $testPath,
            $source.Replace("metadata description = 'Deploys the default mock widget.'", "// metadata description = 'Not real'").Replace(
                "param namePrefix string = '#_namePrefix_#'", "// param namePrefix string = '#_namePrefix_#'"))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.test-metadata-description'
        $result.Issues.Code | Should -Contain 'avm.bicep.test-name-prefix'
    }

    It 'enforces the serviceShort suffix, deployment name, and direct module invocation' {
        $testPath = Join-Path $script:modulePath 'tests' 'e2e' 'waf-aligned' 'main.test.bicep'
        $source = [System.IO.File]::ReadAllText($testPath)
        [System.IO.File]::WriteAllText(
            $testPath,
            $source.Replace('wgtwaf', 'wgtmin').Replace('module testDeployment', 'module other').Replace('-test-', '-other-'))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.test-service-short-suffix'
        $result.Issues.Code | Should -Contain 'avm.bicep.test-deployment'
        $result.Issues.Code | Should -Contain 'avm.bicep.test-deployment-name'
        $result.Issues.Code | Should -Contain 'avm.bicep.test-service-short-duplicate'
    }

    It 'accepts a conditional testDeployment declaration' {
        $testPath = Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep'
        $source = [System.IO.File]::ReadAllText($testPath)
        [System.IO.File]::WriteAllText($testPath, $source.Replace(
                "'../../../main.bicep' = {", "'../../../main.bicep' = if (true) {"))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        @($result.Issues | Where-Object Code -ne 'avm.bicep.convention-incomplete').Count |
            Should -Be 0
    }

    It 'detects duplicate serviceShort values in another module of the repository' {
        $other = Join-Path $script:workingRoot 'avm' 'ptn' 'mock' 'other' 'tests' 'e2e' 'defaults'
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep') `
            -Destination (Join-Path $other 'main.test.bicep')

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $duplicates = @($result.Issues | Where-Object Code -eq 'avm.bicep.test-service-short-duplicate')
        $duplicates.Count | Should -Be 1
        $duplicates[0].Message | Should -Match 'avm/ptn/mock/other/tests/e2e/defaults/main.test.bicep'
    }

    It 'detects duplicate serviceShort values outside avm/' {
        $other = Join-Path $script:workingRoot 'other' 'tests'
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep') `
            -Destination (Join-Path $other 'main.test.bicep')

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $duplicates = @($result.Issues | Where-Object Code -eq 'avm.bicep.test-service-short-duplicate')
        $duplicates.Count | Should -Be 1
        $duplicates[0].Message | Should -Match 'other/tests/main.test.bicep'
    }

    It 'checks required test folders for each scope and rejects a versioned multi-scope parent' {
        Copy-Item -LiteralPath (Join-Path $script:modulePath 'child') `
            -Destination (Join-Path $script:modulePath 'rg-scope') -Recurse

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.multiscope-version'
        @($result.Issues | Where-Object Code -eq 'avm.bicep.scope-test-missing').Count | Should -Be 2
        $result.Issues.Code | Should -Contain 'avm.bicep.test-scope-reference'
    }

    It 'fails closed when repository PSRule configuration is absent' {
        Remove-Item -LiteralPath (Join-Path $script:workingRoot `
                'utilities/pipelines/staticValidation/psrule/ps-rule.yaml')
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.ToolSource | Should -Be 'not-run'
        $result.RequiredBaselines | Should -Be @('Azure.Pillar.Reliability', 'CB.AVM.WAF.Security')
        $result.AdvisoryBaselines | Should -Be @('Azure.Default', 'Azure.Pillar.Security')
        $result.Issues[0].Code | Should -Be 'avm.bicep.psrule-config'
    }
}
