#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).ProviderPath
    $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
    $script:fixtureRoot = Join-Path $script:repoRoot 'tests' 'fixtures' 'bicep-convention'
    . (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $script:moduleRoot 'Avm.Authoring.psd1')

    function Invoke-CompiledTelemetryFixture {
        param($Template, $Scope, [string]$SourcePath, [string]$Root, [switch]$AllDiagnostics)

        $run = InModuleScope 'Avm.Authoring' -Parameters @{
            T = $Template; S = $Scope; P = $SourcePath; R = $Root
        } {
            param($T, $S, $P, $R)
            $inputModule = [pscustomobject]@{
                Template = $T; Scope = $S; Path = $P
                Json = ConvertTo-Json -InputObject $T -Depth 100
            }
            $convention = @{
                CompiledInputs         = @(Get-AvmBicepCompiledConventionInput -Module $inputModule)
                NativeCompiledExpected = 0
            }
            $suitePath = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Resources' 'bicep' 'conventions' 'Compiled.Tests.ps1'
            $summary = Invoke-AvmBicepPesterSuite -Files @($suitePath) -WorkingDirectory $R `
                -Mode Convention -ConventionData $convention -EnvVars @{} -InProcess
            @{
                Summary      = $summary
                Expected     = $convention.NativeCompiledExpected
                NativeIssues = @($summary.Issues |
                        ForEach-Object {
                            New-AvmBicepConventionIssue -Root $R -Path $_.File -Code $_.Code `
                                -Message $_.Message -Severity $_.Severity
                        })
            }
        }
        $run.Expected | Should -BeGreaterThan 11
        $run.Summary.Total | Should -Be $run.Expected
        ($run.Summary.Passed + $run.Summary.Failed) | Should -Be $run.Expected
        @($run.Summary.Issues | Where-Object { $_.Code -like 'avm.bicep.pester-*' }).Count |
            Should -Be 0
        if ($AllDiagnostics) { return $run.NativeIssues }
        return @($run.NativeIssues | Where-Object { $_.Code -like 'avm.bicep.telemetry-*' })
    }

    function Invoke-NativeVersionFixture {
        param([string] $Path, [string[]] $MajorVersionAllowedModules = @())

        InModuleScope 'Avm.Authoring' -Parameters @{ Path = $Path; Allowed = $MajorVersionAllowedModules } {
            param($Path, $Allowed)
            $data = @{
                VersionInputs = @((Get-AvmBicepVersionInput -Scope (Get-AvmBicepConventionScope -Path $Path)))
                MajorVersionAllowedModules = $Allowed
            }

            $suite = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Resources' 'bicep' 'conventions' 'Version.Tests.ps1'
            $summary = Invoke-AvmBicepPesterSuite -Files @($suite) -WorkingDirectory $Path `
                -Mode Convention -ConventionData $data -EnvVars @{} -InProcess
            @{ Summary = $summary; Expected = $data.NativeVersionExpected }
        }
    }

    function Invoke-NativeLayoutFixture {
        param([string] $Root, [object[]] $Scopes)
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $Root; Scopes = $Scopes } {
            param($Root, $Scopes)
            $data = @{
                LayoutInputs = @($Scopes | ForEach-Object { Get-AvmBicepLayoutInput -Scope $_ })
                LayoutExemptions = (Get-AvmBicepConfiguration)['conventionExemptions']
            }
            $suite = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Resources' 'bicep' 'conventions' 'Layout.Tests.ps1'
            $summary = Invoke-AvmBicepPesterSuite -Files @($suite) -WorkingDirectory $Root `
                -Mode Convention -ConventionData $data -EnvVars @{} -InProcess
            @{
                Summary = $summary
                Expected = $data.NativeLayoutExpected
                Issues = @($summary.Issues | ForEach-Object {
                        New-AvmBicepConventionIssue -Root $Root -Path $_.File -Code $_.Code -Message $_.Message -Severity $_.Severity
                    })
            }
        }
    }
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
            Mock Get-AvmBicepPublicationGitState {
                [pscustomobject]@{ GitPath = 'mock-git'; BaseSha = 'fixture'; ChangedPaths = @() }
            }
            Mock Get-AvmBicepPublicationTargetVersion {
                [pscustomobject]@{
                    TargetVersion   = '0.1.0'
                    VersionChanged  = $true
                    PreviousVersion = $null
                    ShouldPublish   = $true
                }
            }
            Mock Get-AvmBicepApiSpecList {
                @{
                    'Microsoft.Storage' = @{
                        storageAccounts = @('2023-05-01')
                    }
                }
            }
            Mock Invoke-WebRequest {
                $name = $Uri.AbsolutePath.Substring(4).Replace('/tags/list', '')
                [pscustomobject]@{
                    StatusCode   = 200
                    Content      = '{"name":"' + $name + '","tags":["0.1.0"]}'
                    Headers      = @{}
                    BaseResponse = [pscustomobject]@{
                        RequestMessage = [pscustomobject]@{ RequestUri = $Uri }
                    }
                }
            }
        }
    }

    It 'runs default packaged compliance through native requirements: <Variant>' -ForEach @(
        @{ Variant = 'valid'; ExpectedCode = '' }
        @{ Variant = 'metadata'; ExpectedCode = 'AVM_METADATA_MISSING' }
        @{ Variant = 'readme'; ExpectedCode = 'avm.bicep.docs-stale' }
        @{ Variant = 'telemetry'; ExpectedCode = 'avm.bicep.telemetry-prefix' }
        @{ Variant = 'filtered'; ExpectedCode = '' }
        @{ Variant = 'filtered-root'; ExpectedCode = '' }
        @{ Variant = 'empty-filter'; ExpectedCode = '' }
        @{ Variant = 'warning'; ExpectedCode = '' }
    ) {
        foreach ($path in @($script:modulePath, (Join-Path $script:modulePath 'child'))) {
            $metadataPath = Join-Path $path 'metadata.json'
            $data = if (Test-Path -LiteralPath $metadataPath) {
                Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -AsHashtable
            } else { @{} }
            $data.moduleDisplayName = 'Mock widget'
            $data.moduleDescription = 'A mock module for native compliance.'
            $data['$schema'] = 'https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json'
            $data.canonicalType = 'helper'
            if ($path -eq $script:modulePath) {
                $data.canonicalType = 'Microsoft.Storage/storageAccounts'
                $data.owners = @()
                $data.telemetryIdPrefix = '46d3xbcp.res.1234567'
                $compiledPath = Join-Path $path 'main.json'
                $compiled = [System.IO.File]::ReadAllText($compiledPath).Replace(
                    '46d3xbcp.res.mock.widget.abc1234', $data.telemetryIdPrefix)
                [System.IO.File]::WriteAllText($compiledPath, $compiled, [System.Text.UTF8Encoding]::new($false))
            }
            $data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataPath
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ Path = $script:modulePath; Variant = $Variant; ExpectedCode = $ExpectedCode } {
            param($Path, $Variant, $ExpectedCode)
            $script:preparedReadmes = @(
                foreach ($modulePath in @($Path, (Join-Path $Path 'child'))) {
                    $file = Join-Path $modulePath 'README.md'
                    $bytes = [System.IO.File]::ReadAllBytes($file)
                    @{
                        IssuePath = $file
                        Case = @{ Current = $bytes; Expected = $bytes; MissingExampleComments = 0 }
                    }
                }
            )
            if ($Variant -eq 'metadata') { Remove-Item -LiteralPath (Join-Path $Path 'metadata.json') }
            if ($Variant -eq 'readme') { $script:preparedReadmes[0].Case.Current = [byte[]]@(1, 2, 3) }
            if ($Variant -eq 'telemetry') {
                $metadataPath = Join-Path $Path 'metadata.json'
                $data = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -AsHashtable
                $data.telemetryIdPrefix = '46d3xbcp.res.7654321'
                $data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataPath
            }
            Mock Invoke-AvmBicepDocs {
                if (-not $PreparationOnly -or -not $CheckDrift) { throw 'Compliance must only prepare docs before its native run.' }
                [pscustomobject]@{ ReadmeInputs = $script:preparedReadmes; Issues = @() }
            }
            if ($Variant -eq 'warning') {
                Mock Get-AvmBicepApiSpecList {
                    @{ 'Microsoft.Storage' = @{ storageAccounts = @('2023-05-01', '2025-04-01') } }
                }
            }
            $selection = @{}
            if ($Variant -in @('filtered', 'filtered-root')) { $selection.TestName = '*Bicep module layout*' }
            if ($Variant -eq 'empty-filter') { $selection.TestName = 'does-not-exist*' }
            $result = Invoke-AvmTestUnit -Path $Path -Recurse:($Variant -ne 'filtered-root') -IncludeCompliance @selection
            $result.ComplianceFile | Should -BeLike '*Resources*bicep*Compliance.Tests.ps1'
            if ($Variant -eq 'filtered') {
                $result.RunsTotal | Should -Be 22
                $result.RunsFiltered | Should -BeGreaterThan 0
            }
            elseif ($Variant -eq 'filtered-root') {
                $result.RunsTotal | Should -Be 18
                $result.RunsFiltered | Should -BeGreaterThan 0
            }
            elseif ($Variant -eq 'empty-filter') {
                $result.RunsTotal | Should -Be 0
                $result.Status | Should -Be 'skipped'
                return
            }
            else { $result.RunsTotal | Should -BeGreaterThan 100 -Because (@($result.Issues | ForEach-Object Message) -join '; ') }
            $result.FilesProcessed | Should -Be 1
            $result.UnitFiles | Should -Be 0
            if ($ExpectedCode) {
                $result.Status | Should -Be 'fail'
                $result.Issues.Code | Should -Contain $ExpectedCode
            }
            else {
                $result.Status | Should -Be 'pass' -Because (@($result.Issues | ForEach-Object Message) -join '; ')
                if ($Variant -eq 'warning') {
                    $result.RunsFailed | Should -BeGreaterThan 0
                    $result.Issues.Severity | Should -Contain 'warning'
                    $result.Issues.Severity | Should -Not -Contain 'error'
                }
                else { $result.RunsFailed | Should -Be 0 }
                ($result.RunsPassed + $result.RunsFailed) | Should -Be $result.RunsTotal
            }
        }
    }

    It 'executes independent native workflow and ownership requirements' {
        $run = InModuleScope 'Avm.Authoring' -Parameters @{
            Path = $script:modulePath; Root = $script:workingRoot
        } {
            param($Path, $Root)
            $scope = Get-AvmBicepConventionScope -Path $Path
            $data = @{
                Root = $Root; RepositoryRoot = $Root
                Workflows      = @(@{ Scope = $scope; Input = Get-AvmBicepConventionWorkflowInput -Scope $scope })
                CodeownerInput = Get-AvmBicepCodeownerInput -RepositoryRoot $Root
            }
            $directory = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Resources' 'bicep' 'conventions'
            $summary = Invoke-AvmBicepPesterSuite -Files @(
                (Join-Path $directory 'Workflow.Tests.ps1'), (Join-Path $directory 'Ownership.Tests.ps1')
            ) -WorkingDirectory $Root -Mode Convention -ConventionData $data -EnvVars @{} -InProcess
            @{ Summary = $summary; Workflow = $data.NativeWorkflowExpected; Ownership = $data.NativeOwnershipExpected }
        }
        $run.Workflow | Should -Be 20
        $run.Ownership | Should -Be 17
        $run.Summary.Total | Should -Be 37
        $run.Summary.Passed | Should -Be 37 -Because (@($run.Summary.Issues | ForEach-Object Message) -join '; ')
        @($run.Summary.Issues) | Should -HaveCount 0
    }

    It 'executes fourteen independent native version and changelog requirements' {
        $run = Invoke-NativeVersionFixture -Path $script:modulePath
        $run.Expected | Should -Be 14
        $run.Summary.Total | Should -Be 14
        $run.Summary.Passed | Should -Be 14 -Because (@($run.Summary.Issues | ForEach-Object Message) -join '; ')
        @($run.Summary.Issues) | Should -HaveCount 0
    }

    It 'preserves the approved module major-version exemption in native tests' {
        Set-Content -LiteralPath (Join-Path $script:modulePath 'version.json') -Value '{"version":"1.0"}'
        $run = Invoke-NativeVersionFixture -Path $script:modulePath -MajorVersionAllowedModules @('avm/res/mock/widget')
        $run.Expected | Should -Be 13
        $run.Summary.Passed | Should -Be 13
        @($run.Summary.Issues) | Should -HaveCount 0
    }

    It 'reports native version requirement <Code> at line <Line>' -ForEach @(
        @{ Code = 'version-invalid'; File = 'version.json'; Content = '{'; Line = 1 }
        @{ Code = 'version-format'; File = 'version.json'; Content = '[]'; Line = 1 }
        @{ Code = 'version-format'; File = 'version.json'; Content = '{"version":1}'; Line = 1 }
        @{ Code = 'version-format'; File = 'version.json'; Content = '{"version":"0.1.0"}'; Line = 1 }
        @{ Code = 'version-major'; File = 'version.json'; Content = '{"version":"1.0"}'; Line = 1 }
        @{ Code = 'changelog-empty'; File = 'CHANGELOG.md'; Content = ''; Line = 1 }
        @{ Code = 'changelog-header'; File = 'CHANGELOG.md'; Content = '# Wrong'; Line = 1 }
        @{ Code = 'changelog-versions-missing'; File = 'CHANGELOG.md'; Content = '# Changelog'; Line = 1 }
        @{ Code = 'changelog-version'; File = 'CHANGELOG.md'; Content = "## 0.1`n"; Line = 1 }
        @{ Code = 'changelog-order'; File = 'CHANGELOG.md'; Content = "## 0.1.0`n## 0.1.0`n"; Line = 2 }
        @{ Code = 'changelog-section'; File = 'CHANGELOG.md'; Content = "## 0.1.0`n### Changes`n- change`n"; Line = 1 }
        @{ Code = 'changelog-section-empty'; File = 'CHANGELOG.md'; Content = "## 0.1.0`n### Changes`n`n### Breaking Changes`n- None`n"; Line = 2 }
        @{ Code = 'changelog-section-order'; File = 'CHANGELOG.md'; Content = "## 0.1.0`n### Breaking Changes`n- None`n### Changes`n- change`n"; Line = 1 }
    ) {
        Set-Content -LiteralPath (Join-Path $script:modulePath $File) -Value $Content
        $run = Invoke-NativeVersionFixture -Path $script:modulePath
        $run.Summary.Total | Should -Be $run.Expected
        ($run.Summary.Passed + $run.Summary.Failed) | Should -Be $run.Expected
        $issue = @($run.Summary.Issues | Where-Object Code -eq "avm.bicep.$Code")
        $issue | Should -Not -BeNullOrEmpty
        $issue[0].Line | Should -Be $Line
        $issue[0].File | Should -Be (Join-Path $script:modulePath $File)
        $issue[0].Severity | Should -Be 'error'
        @($run.Summary.Issues | Where-Object Code -like 'avm.bicep.pester-*') | Should -HaveCount 0
    }

    It 'runs twenty-seven independent native requirements for the three test sources' {
        $run = InModuleScope 'Avm.Authoring' -Parameters @{
            Path = $script:modulePath; Root = $script:workingRoot
        } {
            param($Path, $Root)
            $scope = Get-AvmBicepConventionScope -Path $Path
            $compiled = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
            $template = [System.IO.File]::ReadAllText((Join-Path $Root 'compiled-e2e.json')) | ConvertFrom-Json -AsHashtable
            $sources = @(Get-ChildItem -LiteralPath (Join-Path $Path 'tests') -Recurse -File -Filter 'main.test.bicep')
            foreach ($source in $sources) { $compiled[$source.FullName] = $template }
            $data = @{
                ServiceShortIndex = @{}
                TestSourceInputs = @($sources | ForEach-Object {
                        Get-AvmBicepTestSourceInput -SourceFile ([pscustomobject]@{ Path = $_.FullName; Scope = $scope }) `
                            -CompiledTests $compiled
                    })
            }
            $suite = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Resources' 'bicep' 'conventions' 'TestSource.Tests.ps1'
            $summary = Invoke-AvmBicepPesterSuite -Files @($suite) -WorkingDirectory $Path `
                -Mode Convention -ConventionData $data -EnvVars @{} -InProcess
            @{ Summary = $summary; Expected = $data.NativeTestSourceExpected }
        }
        $run.Expected | Should -Be 27
        $run.Summary.Total | Should -Be 27
        $run.Summary.Passed | Should -Be 27 -Because (@($run.Summary.Issues | ForEach-Object Message) -join '; ')
        @($run.Summary.Issues) | Should -HaveCount 0
    }

    It 'rejects a test source without <Declaration>' -ForEach @(
        @{ Declaration = 'metadata name'; Pattern = "(?m)^metadata name[^\r\n]*"; Code = 'avm.bicep.test-metadata-name' }
        @{ Declaration = 'serviceShort'; Pattern = "(?m)^param serviceShort[^\r\n]*"; Code = 'avm.bicep.test-service-short' }
    ) {
        $path = Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep'
        $source = [System.IO.File]::ReadAllText($path)
        [System.IO.File]::WriteAllText($path, [regex]::Replace($source, $Pattern, ''))
        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $issue = @($result.Issues | Where-Object Code -eq $Code)
        $issue | Should -HaveCount 1
        $issue[0].File | Should -Be 'tests/e2e/defaults/main.test.bicep'
    }

    It 'reports malformed UTF-8 test source instead of hiding a preparation failure' {
        $path = Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep'
        [System.IO.File]::WriteAllBytes($path, [byte[]]@(0xC3, 0x28))
        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.test-source-read'
    }

    It 'executes twenty-two independent native root and child layout requirements' {
        $scopes = InModuleScope 'Avm.Authoring' -Parameters @{ Path = $script:modulePath } {
            param($Path)
            Get-AvmBicepConventionScope -Path $Path
            Get-AvmBicepConventionScope -Path (Join-Path $Path 'child')
        }
        $run = Invoke-NativeLayoutFixture -Root $script:workingRoot -Scopes @($scopes)
        $run.Expected | Should -Be 22
        $run.Summary.Total | Should -Be 22
        $run.Summary.Passed | Should -Be 22 -Because (@($run.Summary.Issues | ForEach-Object Message) -join '; ')
        $run.Issues | Should -HaveCount 0
    }

    It 'executes four native publication requirements from prepared history and changelog data' {
        $run = InModuleScope 'Avm.Authoring' -Parameters @{ Path = $script:modulePath; Root = $script:workingRoot } {
            param($Path, $Root)
            $scope = Get-AvmBicepConventionScope -Path $Path
            $publication = Get-AvmBicepPublicationInput -RepositoryRoot $Root -Scopes @($scope)
            @($publication.Issues) | Should -HaveCount 0
            $data = @{
                PublicationConventionInput = Get-AvmBicepPublicationConventionInput -RepositoryRoot $Root `
                    -Publication $publication -VersionInputs @((Get-AvmBicepVersionInput -Scope $scope))
            }
            $suite = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Resources' 'bicep' 'conventions' 'Publication.Tests.ps1'
            $summary = Invoke-AvmBicepPesterSuite -Files @($suite) -WorkingDirectory $Root `
                -Mode Convention -ConventionData $data -EnvVars @{} -InProcess
            @{ Summary = $summary; Expected = $data.NativePublicationExpected }
        }
        $run.Expected | Should -Be 4
        $run.Summary.Total | Should -Be 4
        $run.Summary.Passed | Should -Be 4
        @($run.Summary.Issues) | Should -HaveCount 0
    }

    It 'rejects noncanonical layout casing at <RelativePath>' -ForEach @(
        @{ RelativePath = 'tests'; NewName = 'Tests'; Code = 'avm.bicep.tests-missing' }
        @{ RelativePath = 'tests/e2e'; NewName = 'E2e'; Code = 'avm.bicep.e2e-missing' }
        @{ RelativePath = 'tests/e2e/defaults/main.test.bicep'; NewName = 'Main.test.bicep'; Code = 'avm.bicep.test-file-missing' }
        @{ RelativePath = 'CHANGELOG.md'; NewName = 'ChangeLog.md'; Code = 'avm.bicep.publication-changelog' }
    ) {
        Rename-Item -LiteralPath (Join-Path $script:modulePath $RelativePath) -NewName $NewName
        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain $Code
    }

    It 'reports malformed UTF-8 deployment exclusion content' {
        [System.IO.File]::WriteAllBytes((Join-Path $script:modulePath 'tests' 'e2e' 'max' '.e2eignore'), [byte[]]@(0xC3, 0x28))
        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.e2eignore-read'
    }

    It 'rejects a mis-cased deployment exclusion file' {
        Rename-Item -LiteralPath (Join-Path $script:modulePath 'tests' 'e2e' 'max' '.e2eignore') -NewName '.E2eignore'
        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.e2eignore-file'
    }

    It 'reports unreadable publication changelog content without a family crash' {
        [System.IO.File]::WriteAllBytes((Join-Path $script:modulePath 'CHANGELOG.md'), [byte[]]@(0xC3, 0x28))
        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.publication-changelog'
        $result.Issues.Code | Should -Not -Contain 'avm.bicep.convention-rule-failed'
    }

    It 'checks the complete root and child fixture without uncovered convention families' {
        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck

        $result.Engine | Should -Be 'bicep'
        $result.Status | Should -Be 'pass' -Because (@($result.Issues | ForEach-Object Message) -join '; ')
        $result.ScopesChecked | Should -Be 2
        $result.CompiledFiles | Should -Be 5
        $result.CompilerSource | Should -Be 'fixture'
        $result.UncoveredFamilies.Count | Should -Be 0
        $result.Issues.Count | Should -Be 0
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 5 -ParameterFilter {
                $ArgumentList[0] -eq 'build' -and $ArgumentList[1] -eq '--stdout'
            }
        }
    }

    It 'rejects a compiled template missing required element <Element>' -TestCases @(
        @{ Element = '$schema' }
        @{ Element = 'contentVersion' }
        @{ Element = 'resources' }
    ) {
        param($Element)
        $jsonPath = Join-Path $script:modulePath 'main.json'
        $template = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -AsHashtable
        $null = $template.Remove($Element)
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.compile'
        @($result.Issues | Where-Object { $_.Code -like 'avm.bicep.convention-suite-*' }).Count |
            Should -Be 0
        $scope = InModuleScope 'Avm.Authoring' -Parameters @{ Path = $script:modulePath } {
            param($Path)
            Get-AvmBicepConventionScope -Path $Path
        }
        $issues = @(Invoke-CompiledTelemetryFixture -Template $template -Scope $scope `
                -SourcePath (Join-Path $script:modulePath 'main.bicep') -Root $script:workingRoot -AllDiagnostics)
        $issues.Code | Should -Contain 'avm.bicep.compiled-required-fields'
    }

    It 'reports an outdated compiled resource API as an advisory without failing the convention check' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmBicepApiSpecList {
                @{
                    'Microsoft.Storage' = @{
                        storageAccounts = @(
                            '2023-05-01', '2023-12-01', '2024-05-01', '2025-01-01',
                            '2025-06-01', '2025-09-01', '2026-01-01'
                        )
                    }
                }
            }
        }

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck

        $result.Status | Should -Be 'pass'
        $result.Issues.Code | Should -Contain 'avm.bicep.api-version-outdated'
        @($result.Issues | Where-Object Code -EQ 'avm.bicep.api-version-outdated' |
                Where-Object Severity -EQ 'warning').Count | Should -BeGreaterThan 0
    }

    It 'fails closed when the API-version source cannot be read' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmBicepApiSpecList {
                throw [AvmConfigurationException]::new('API catalogue unavailable')
            }
        }

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.api-specs-unavailable'
        $issue = @($result.Issues | Where-Object Code -EQ 'avm.bicep.api-specs-unavailable')
        $issue.Count | Should -Be 1
        $issue[0].Severity | Should -Be 'error'
    }

    It 'reports a missing module workflow once for its top-level scope' {
        $path = Join-Path $script:workingRoot '.github' 'workflows' 'avm.res.mock.widget.yml'
        Remove-Item -LiteralPath $path

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $missing = @($result.Issues | Where-Object Code -EQ 'avm.bicep.workflow-file')
        $missing.Count | Should -Be 1
        $missing[0].File | Should -Be '.github/workflows/avm.res.mock.widget.yml'
        $result.Status | Should -Be 'fail'
    }

    It 'rejects malformed YAML without treating the workflow as checked' {
        $path = Join-Path $script:workingRoot '.github' 'workflows' 'avm.res.mock.widget.yml'
        [System.IO.File]::WriteAllText($path, 'on: [unterminated')

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        @($result.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.workflow-parse' -and
                $_.File -eq '.github/workflows/avm.res.mock.widget.yml'
            }).Count | Should -Be 1
    }

    It 'fails with a named diagnostic when the exact YAML parser is unavailable' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-Module {
                & (Get-Command -Name Get-Module -CommandType Cmdlet) @PesterBoundParameters
            }
            Mock Get-Module { @() } -ParameterFilter {
                $ListAvailable -and $Name -eq 'powershell-yaml'
            }
        }

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $parserIssue = @($result.Issues | Where-Object Code -EQ 'avm.bicep.workflow-parse')
        $parserIssue.Count | Should -Be 1
        $parserIssue[0].Message | Should -Match 'Install-PSResource'
        $result.Status | Should -Be 'fail'
    }

    It 'checks each top-level workflow separately in a monorepo' {
        $second = Join-Path $script:workingRoot 'avm' 'res' 'mock' 'gadget'
        Copy-Item -LiteralPath $script:modulePath -Destination $second -Recurse
        $workflowDirectory = Join-Path $script:workingRoot '.github' 'workflows'
        $first = Join-Path $workflowDirectory 'avm.res.mock.widget.yml'
        $other = Join-Path $workflowDirectory 'avm.res.mock.gadget.yml'
        $content = [System.IO.File]::ReadAllText($first).Replace('widget', 'gadget')
        [System.IO.File]::WriteAllText($other, $content)
        $context = [pscustomobject]@{
            Kind = 'bicep-monorepo'; Root = $script:workingRoot; Ecosystem = 'bicep'
        }

        $valid = InModuleScope 'Avm.Authoring' -Parameters @{ C = $context } {
            param($C)
            Invoke-AvmBicepCheckConvention -Context $C
        }
        @($valid.Issues | Where-Object {
                $_.Code -like 'avm.bicep.workflow-*' -or $_.Code -like 'avm.bicep.codeowners-*'
            }).Count | Should -Be 0

        Remove-Item -LiteralPath $other
        $invalid = InModuleScope 'Avm.Authoring' -Parameters @{ C = $context } {
            param($C)
            Invoke-AvmBicepCheckConvention -Context $C
        }
        $workflowIssues = @($invalid.Issues | Where-Object Code -EQ 'avm.bicep.workflow-file')
        $workflowIssues.Count | Should -Be 1
        $workflowIssues[0].File | Should -Be '.github/workflows/avm.res.mock.gadget.yml'
    }

    It 'names invalid workflow declarations: <Case>' -TestCases @(
        @{ Case = 'missing environment variable'; Find = 'modulePath: avm/res/mock/widget'; Replacement = 'otherPath: avm/res/mock/widget'; ExpectedCode = 'avm.bicep.workflow-env' }
        @{ Case = 'wrong module path'; Find = 'modulePath: avm/res/mock/widget'; Replacement = 'modulePath: avm/res/mock/other'; ExpectedCode = 'avm.bicep.workflow-module-path' }
        @{ Case = 'wrong workflow path'; Find = 'workflowPath: .github/workflows/avm.res.mock.widget.yml'; Replacement = 'workflowPath: .github/workflows/other.yml'; ExpectedCode = 'avm.bicep.workflow-path' }
        @{ Case = 'missing dispatch input'; Find = 'removeDeployment:'; Replacement = 'otherInput:'; ExpectedCode = 'avm.bicep.workflow-dispatch' }
        @{ Case = 'disabled static default'; Find = "staticValidation:`n        type: boolean`n        default: true"; Replacement = "staticValidation:`n        type: boolean`n        default: false"; ExpectedCode = 'avm.bicep.workflow-staticValidation-default' }
        @{ Case = 'missing deployment default'; Find = "deploymentValidation:`n        type: boolean`n        default: true"; Replacement = "deploymentValidation:`n        type: boolean"; ExpectedCode = 'avm.bicep.workflow-deploymentValidation-default' }
        @{ Case = 'custom location default'; Find = "customLocation:`n        type: string"; Replacement = "customLocation:`n        type: string`n        default: eastus"; ExpectedCode = 'avm.bicep.workflow-custom-location' }
        @{ Case = 'other push branch'; Find = "      - main`n    paths:"; Replacement = "      - other`n    paths:"; ExpectedCode = 'avm.bicep.workflow-push-branches' }
        @{ Case = 'missing push event'; Find = "  push:`n    branches:"; Replacement = "  renamedPush:`n    branches:"; ExpectedCode = 'avm.bicep.workflow-push-branches' }
        @{ Case = 'missing push paths'; Find = '    paths:'; Replacement = '    otherPaths:'; ExpectedCode = 'avm.bicep.workflow-push-paths-missing' }
        @{ Case = 'missing push filter'; Find = "'!*/**/README.md'"; Replacement = "'!*/**/docs.md'"; ExpectedCode = 'avm.bicep.workflow-push-paths-missing' }
        @{ Case = 'extra push filter'; Find = "      - '!avm/**/metadata.json'"; Replacement = "      - extra/**`n      - '!avm/**/metadata.json'"; ExpectedCode = 'avm.bicep.workflow-push-paths-excess' }
        @{ Case = 'tag push trigger'; Find = "  push:`n    branches:"; Replacement = "  push:`n    tags:`n      - 'v*'`n    branches:"; ExpectedCode = 'avm.bicep.workflow-push-options' }
        @{ Case = 'unreviewed trigger'; Find = '  push:'; Replacement = "  schedule:`n    - cron: '0 0 * * *'`n  push:"; ExpectedCode = 'avm.bicep.workflow-trigger' }
        @{ Case = 'README filter before positive filter'; Find = "      - avm/res/mock/widget/**`n      - '!*/**/README.md'"; Replacement = "      - '!*/**/README.md'`n      - avm/res/mock/widget/**"; ExpectedCode = 'avm.bicep.workflow-push-paths-order' }
        @{ Case = 'metadata filter out of order'; Find = "      - '!*/**/README.md'`n      - '!avm/**/metadata.json'"; Replacement = "      - '!avm/**/metadata.json'`n      - '!*/**/README.md'"; ExpectedCode = 'avm.bicep.workflow-push-metadata-last' }
        @{ Case = 'fork guard missing'; Find = 'Azure/bicep-registry-modules'; Replacement = 'Contoso/example'; ExpectedCode = 'avm.bicep.workflow-condition' }
        @{ Case = 'cancellation guard missing'; Find = '!cancelled() && '; Replacement = ''; ExpectedCode = 'avm.bicep.workflow-condition' }
        @{ Case = 'fork guard negated by disjunction'; Find = "github.event_name != 'workflow_dispatch') }}"; Replacement = "github.event_name != 'workflow_dispatch') || true }}"; ExpectedCode = 'avm.bicep.workflow-condition' }
    ) {
        param($Case, $Find, $Replacement, $ExpectedCode)

        $path = Join-Path $script:workingRoot '.github' 'workflows' 'avm.res.mock.widget.yml'
        $original = [System.IO.File]::ReadAllText($path)
        $original.Contains($Find) | Should -BeTrue
        [System.IO.File]::WriteAllText($path, $original.Replace($Find, $Replacement))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain $ExpectedCode
        $result.Status | Should -Be 'fail'
    }

    It 'rejects noncanonical workflow directory casing: <Case>' -TestCases @(
        @{ Case = 'GitHub'; RelativePath = '.github'; NewName = '.GITHUB' }
        @{ Case = 'workflows'; RelativePath = '.github/workflows'; NewName = 'Workflows' }
    ) {
        param($Case, $RelativePath, $NewName)

        $directory = Join-Path $script:workingRoot $RelativePath
        Rename-Item -LiteralPath $directory -NewName $NewName
        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck

        $result.Issues.Code | Should -Contain 'avm.bicep.workflow-file'
        if ($Case -eq 'GitHub') {
            $result.Issues.Code | Should -Contain 'avm.bicep.codeowners-file'
        }
    }

    It 'rejects a missing CODEOWNERS file without silently skipping repository governance' {
        $path = Join-Path $script:workingRoot '.github' 'CODEOWNERS'
        Remove-Item -LiteralPath $path

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $issue = @($result.Issues | Where-Object Code -EQ 'avm.bicep.codeowners-file')
        $issue.Count | Should -Be 1
        $issue[0].File | Should -Be '.github/CODEOWNERS'
    }

    It 'checks the CODEOWNERS default, ownerless module tree, and final overrides' {
        $path = Join-Path $script:workingRoot '.github' 'CODEOWNERS'
        $content = [System.IO.File]::ReadAllText($path).
        Replace('* @Azure/azure-verified-modules-tooling-contributors', '* @Contoso/team').
        Replace('/avm/', '/avm/ @Contoso/team').
        Replace('metadata.json @Azure/azure-verified-modules-engineering-owners', 'metadata.json @Contoso/team')
        [System.IO.File]::WriteAllText($path, $content)

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.codeowners-default'
        $result.Issues.Code | Should -Contain 'avm.bicep.codeowners-module'
        $result.Issues.Code | Should -Contain 'avm.bicep.codeowners-override'
    }

    It 'reports duplicate and module-specific CODEOWNERS patterns with line numbers' {
        $path = Join-Path $script:workingRoot '.github' 'CODEOWNERS'
        [System.IO.File]::AppendAllText(
            $path, "/avm/res/mock/widget/ @Contoso/team`nmetadata.json @Contoso/team`n")

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $moduleRule = @($result.Issues | Where-Object Code -EQ 'avm.bicep.codeowners-per-module')
        $duplicate = @($result.Issues | Where-Object Code -EQ 'avm.bicep.codeowners-duplicate')
        $moduleRule.Count | Should -Be 1
        $moduleRule[0].Line | Should -BeGreaterThan 2
        $duplicate.Count | Should -Be 1
        $duplicate[0].Line | Should -BeGreaterThan $moduleRule[0].Line
    }

    It 'rejects CODEOWNERS patterns that can override ownerless modules: <Case>' -TestCases @(
        @{ Case = 'unanchored module entry'; Pattern = 'avm/res/mock/widget/** @Contoso/team'; ExpectedCode = 'avm.bicep.codeowners-per-module' }
        @{ Case = 'unanchored module glob'; Pattern = 'avm/** @Contoso/team'; ExpectedCode = 'avm.bicep.codeowners-per-module' }
        @{ Case = 'broad glob'; Pattern = '**/widget/** @Contoso/team'; ExpectedCode = 'avm.bicep.codeowners-module-override' }
        @{ Case = 'root wildcard'; Pattern = '/** @Contoso/team'; ExpectedCode = 'avm.bicep.codeowners-module-override' }
    ) {
        param($Case, $Pattern, $ExpectedCode)

        $path = Join-Path $script:workingRoot '.github' 'CODEOWNERS'
        $content = [System.IO.File]::ReadAllText($path)
        $anchor = '*avm.core.team.tests.ps1 @Azure/azure-verified-modules-tooling-contributors'
        [System.IO.File]::WriteAllText($path, $content.Replace($anchor, "$Pattern`n$anchor"))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $issue = @($result.Issues | Where-Object Code -EQ $ExpectedCode)
        $issue.Count | Should -Be 1
        $issue[0].Line | Should -BeGreaterThan 2
    }

    It 'allows additional ownership patterns anchored outside the module tree' {
        $path = Join-Path $script:workingRoot '.github' 'CODEOWNERS'
        $content = [System.IO.File]::ReadAllText($path)
        $anchor = '*avm.core.team.tests.ps1 @Azure/azure-verified-modules-tooling-contributors'
        [System.IO.File]::WriteAllText($path, $content.Replace($anchor, "/docs/** @Contoso/team`n$anchor"))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        @($result.Issues | Where-Object { $_.Code -like 'avm.bicep.codeowners-*' }).Count |
            Should -Be 0
    }

    It 'names a CODEOWNERS file that cannot be decoded as UTF-8' {
        $path = Join-Path $script:workingRoot '.github' 'CODEOWNERS'
        [System.IO.File]::WriteAllBytes($path, [byte[]]@(0xC3, 0x28))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $issue = @($result.Issues | Where-Object Code -EQ 'avm.bicep.codeowners-read')
        $issue.Count | Should -Be 1
        $issue[0].File | Should -Be '.github/CODEOWNERS'
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
        $failed = @($result.Issues | Where-Object Code -EQ 'avm.bicep.compile')
        $result.CompiledFiles | Should -Be 3
        $failed.Count | Should -Be 2
        $failed.File | Should -Contain 'child/main.bicep'
        $failed.File | Should -Contain 'tests/e2e/waf-aligned/main.test.bicep'
        $failed.Message | Should -Match 'BCP999'
        $result.Status | Should -Be 'fail'
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
            }).Count | Should -Be 2 -Because 'file availability and the nonempty prefix are independently reported requirements'
    }

    It 'accepts the shipped canonical scaffold telemetry declaration and description' {
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
            'Optional. Enable/Disable usage telemetry for module.'
        $template['resources'] = @($template['resources'][1])
        $template['resources'][0]['name'] = "[format('{0}.mock', variables('telemetryIdPrefix'))]"
        $scope = InModuleScope 'Avm.Authoring' -Parameters @{ P = $scaffold } {
            param($P)
            Get-AvmBicepConventionScope -Path $P
        }

        $issues = @(Invoke-CompiledTelemetryFixture -Template $template -Scope $scope `
                -SourcePath $sourcePath -Root $script:workingRoot)
        $issues.Count | Should -Be 0 -Because ($issues | ConvertTo-Json -Compress -Depth 6)
    }

    It 'accepts the previously shipped telemetry source and compiled alias throughout convention' {
        $sourcePath = Join-Path $script:modulePath 'main.bicep'
        $source = [System.IO.File]::ReadAllText($sourcePath)
        $source = $source.Replace(
            'var telemetryIdPrefix = loadJsonContent(''metadata.json'', ''telemetryIdPrefix'')',
            'var avmTelemetryIdPrefix = loadJsonContent(''metadata.json'', ''$.telemetryIdPrefix'')')
        $source = $source.Replace(
            'Optional. Enable/Disable usage telemetry for module.',
            'Optional. Enable/disable usage telemetry for this module.')
        $source = $source.Replace('${telemetryIdPrefix}-test', '${avmTelemetryIdPrefix}-test')
        [System.IO.File]::WriteAllText($sourcePath, $source)

        $jsonPath = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json -AsHashtable
        $template['parameters']['enableTelemetry']['metadata']['description'] = `
            'Optional. Enable/disable usage telemetry for this module.'
        $template['variables']['avmTelemetryIdPrefix'] = $template['variables']['telemetryIdPrefix']
        $null = $template['variables'].Remove('telemetryIdPrefix')
        $template['resources'][1]['name'] = "[format('{0}-test', variables('avmTelemetryIdPrefix'))]"
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        @($result.Issues | Where-Object Code -Like 'avm.bicep.telemetry-*').Count |
            Should -Be 0
        $result.Issues.Count | Should -Be 0
        $result.Status | Should -Be 'pass'
    }

    It 'rejects mixed telemetry declarations and a mismatched selector for the source variable' {
        $sourcePath = Join-Path $script:modulePath 'main.bicep'
        $source = [System.IO.File]::ReadAllText($sourcePath)
        $source += "`nvar avmTelemetryIdPrefix = loadJsonContent('metadata.json', '$.telemetryIdPrefix')`n"
        [System.IO.File]::WriteAllText($sourcePath, $source)

        $mixed = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $mixed.Issues.Code | Should -Contain 'avm.bicep.telemetry-source'

        $source = $source.Replace(
            'var telemetryIdPrefix = loadJsonContent(''metadata.json'', ''telemetryIdPrefix'')', '')
        $source = $source.Replace(
            'var avmTelemetryIdPrefix = loadJsonContent(''metadata.json'', ''$.telemetryIdPrefix'')',
            'var avmTelemetryIdPrefix = loadJsonContent(''metadata.json'', ''telemetryIdPrefix'')')
        [System.IO.File]::WriteAllText($sourcePath, $source)

        $mismatched = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $mismatched.Issues.Code | Should -Contain 'avm.bicep.telemetry-source'
    }

    It 'rejects source literals that only appear as commented-out telemetry declarations' {
        $sourcePath = Join-Path $script:modulePath 'main.bicep'
        $source = [System.IO.File]::ReadAllText($sourcePath)
        $source = $source.Replace(
            'var telemetryIdPrefix = loadJsonContent(''metadata.json'', ''telemetryIdPrefix'')',
            '// var telemetryIdPrefix = loadJsonContent(''metadata.json'', ''telemetryIdPrefix'')')
        [System.IO.File]::WriteAllText($sourcePath, $source)

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-source'
    }

    It 'rejects any description other than the two exact approved telemetry descriptions: <Case>' -TestCases @(
        @{ Case = 'canonical typo'; Description = 'Optional. Enable/disable usage telemetry for module.' }
        @{ Case = 'legacy typo'; Description = 'Optional. Enable/Disable usage telemetry for this module.' }
    ) {
        param($Case, $Description)

        $jsonPath = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json -AsHashtable
        $template['parameters']['enableTelemetry']['metadata']['description'] = $Description
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-parameter'
    }

    It 'requires each exact telemetry description to match its source form: <Case>' -TestCases @(
        @{ Case = 'canonical source and legacy description'; ShippedSource = $false; Description = 'Optional. Enable/disable usage telemetry for this module.' }
        @{ Case = 'legacy source and canonical description'; ShippedSource = $true; Description = 'Optional. Enable/Disable usage telemetry for module.' }
    ) {
        param($Case, $ShippedSource, $Description)

        $jsonPath = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json -AsHashtable
        $template['parameters']['enableTelemetry']['metadata']['description'] = $Description
        if ($ShippedSource) {
            $sourcePath = Join-Path $script:modulePath 'main.bicep'
            $source = [System.IO.File]::ReadAllText($sourcePath).Replace(
                'var telemetryIdPrefix = loadJsonContent(''metadata.json'', ''telemetryIdPrefix'')',
                'var avmTelemetryIdPrefix = loadJsonContent(''metadata.json'', ''$.telemetryIdPrefix'')')
            $source = $source.Replace('${telemetryIdPrefix}-test', '${avmTelemetryIdPrefix}-test')
            [System.IO.File]::WriteAllText($sourcePath, $source)
            $template['variables']['avmTelemetryIdPrefix'] = $template['variables']['telemetryIdPrefix']
            $null = $template['variables'].Remove('telemetryIdPrefix')
            $template['resources'][1]['name'] = "[format('{0}-test', variables('avmTelemetryIdPrefix'))]"
        }
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-parameter'
    }

    It 'rejects a spoofed deployment name and an alias that cannot resolve to metadata' {
        $jsonPath = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json -AsHashtable
        $template['resources'][1]['name'] = "[format('46d3xbcp.res.mock.widget.abc1234-test')]"
        $template['variables']['telemetryIdPrefix'] = '[variables(''$fxv#missing'')]'
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-name'
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-prefix'
    }

    It 'rejects a conditional telemetry name that can bypass the metadata prefix' {
        $jsonPath = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json -AsHashtable
        $template['parameters']['usePrefix'] = @{
            type = 'bool'; defaultValue = $false
            metadata = @{ description = 'Optional. Use the telemetry prefix.' }
        }
        $template['resources'][1]['name'] = `
            "[if(parameters('usePrefix'), format('{0}-test', variables('telemetryIdPrefix')), 'fake-test')]"
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-name'
    }

    It 'accepts a telemetry name built by concatenating the metadata prefix first' {
        $jsonPath = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json -AsHashtable
        $template['resources'][1]['name'] = "[concat(variables('telemetryIdPrefix'), '-test')]"
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        @($result.Issues | Where-Object Code -Like 'avm.bicep.telemetry-*').Count |
            Should -Be 0
    }

    It 'requires a real boolean telemetry default and rejects uppercase hardcoded prefixes' {
        $sourcePath = Join-Path $script:modulePath 'main.bicep'
        $source = [System.IO.File]::ReadAllText($sourcePath).Replace(
            'var telemetryIdPrefix = loadJsonContent(''metadata.json'', ''telemetryIdPrefix'')',
            "var telemetryIdPrefix = '46D3XBCP.res.mock.widget.abc1234'")
        [System.IO.File]::WriteAllText($sourcePath, $source)
        $jsonPath = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json -AsHashtable
        $template['parameters']['enableTelemetry']['defaultValue'] = 'true'
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-parameter'
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-source'
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-literal'
    }

    Context 'Versioned child telemetry' {
        BeforeEach {
            $script:versionedChildPath = Join-Path $script:modulePath 'child'
            foreach ($name in @('main.bicep', 'main.json', 'metadata.json', 'version.json')) {
                Copy-Item -LiteralPath (Join-Path $script:modulePath $name) `
                    -Destination (Join-Path $script:versionedChildPath $name) -Force
            }
        }

        It 'accepts the <Form> source, description, alias and deployment in a versioned child' -TestCases @(
            @{ Form = 'canonical'; ShippedSource = $false }
            @{ Form = 'shipped'; ShippedSource = $true }
        ) {
            param($Form, $ShippedSource)

            $sourcePath = Join-Path $script:versionedChildPath 'main.bicep'
            $jsonPath = Join-Path $script:versionedChildPath 'main.json'
            $template = [System.IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json -AsHashtable
            if ($ShippedSource) {
                $source = [System.IO.File]::ReadAllText($sourcePath).Replace(
                    'var telemetryIdPrefix = loadJsonContent(''metadata.json'', ''telemetryIdPrefix'')',
                    'var avmTelemetryIdPrefix = loadJsonContent(''metadata.json'', ''$.telemetryIdPrefix'')')
                $source = $source.Replace('${telemetryIdPrefix}-test', '${avmTelemetryIdPrefix}-test')
                [System.IO.File]::WriteAllText($sourcePath, $source)
                $template['parameters']['enableTelemetry']['metadata']['description'] = `
                    'Optional. Enable/disable usage telemetry for this module.'
                $template['variables']['avmTelemetryIdPrefix'] = $template['variables']['telemetryIdPrefix']
                $null = $template['variables'].Remove('telemetryIdPrefix')
                $template['resources'][1]['name'] = "[format('{0}-test', variables('avmTelemetryIdPrefix'))]"
            }
            $scope = InModuleScope 'Avm.Authoring' -Parameters @{ P = $script:versionedChildPath } {
                param($P)
                Get-AvmBicepConventionScope -Path $P
            }
            $issues = @(Invoke-CompiledTelemetryFixture -Template $template -Scope $scope `
                    -SourcePath $sourcePath -Root $script:workingRoot)
            $issues.Count | Should -Be 0
        }

        It 'reports a child-scoped condition, output and alias mismatch' {
            $sourcePath = Join-Path $script:versionedChildPath 'main.bicep'
            $template = [System.IO.File]::ReadAllText(
                (Join-Path $script:versionedChildPath 'main.json')) | ConvertFrom-Json -AsHashtable
            $template['variables']['telemetryIdPrefix'] = '[variables(''$fxv#missing'')]'
            $template['resources'][1]['condition'] = '[false()]'
            $template['resources'][1]['properties']['template']['outputs']['telemetry']['value'] = 'missing'
            $scope = InModuleScope 'Avm.Authoring' -Parameters @{ P = $script:versionedChildPath } {
                param($P)
                Get-AvmBicepConventionScope -Path $P
            }
            $issues = @(Invoke-CompiledTelemetryFixture -Template $template -Scope $scope `
                    -SourcePath $sourcePath -Root $script:workingRoot)
            $issues.Code | Should -Contain 'avm.bicep.telemetry-condition'
            $issues.Code | Should -Contain 'avm.bicep.telemetry-output'
            $issues.Code | Should -Contain 'avm.bicep.telemetry-prefix'
            @($issues | Where-Object {
                    $_.File -ne 'avm/res/mock/widget/child/main.bicep'
                }).Count | Should -Be 0
        }
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
        $patternIssues = @(Invoke-CompiledTelemetryFixture -Template $template -Scope $scope `
                -SourcePath (Join-Path $script:modulePath 'main.bicep') -Root $script:modulePath)
        @($patternIssues | Where-Object { $_.Code -like 'avm.bicep.telemetry-child-*' }).Count |
            Should -Be 0
    }

    It 'does not accept a string false as the referenced-module telemetry switch' {
        $rootJson = Join-Path $script:modulePath 'main.json'
        $template = [System.IO.File]::ReadAllText($rootJson) | ConvertFrom-Json -AsHashtable
        $template['variables']['enableReferencedModulesTelemetry'] = 'false'
        $template['resources'] += @{
            type       = 'Microsoft.Resources/deployments'
            name       = 'nested'
            properties = @{
                template   = @{ parameters = @{ enableTelemetry = @{ type = 'bool' } } }
                parameters = @{ enableTelemetry = @{ value = "[variables('enableReferencedModulesTelemetry')]" } }
            }
        }
        $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $rootJson -Encoding utf8NoBOM

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.telemetry-child-variable'
    }

    It 'reports invalid compiled e2e JSON rather than falling back to source-only deployment checks' {
        [System.IO.File]::WriteAllText((Join-Path $script:workingRoot 'compiled-e2e.json'), '{invalid')

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $compiledErrors = @($result.Issues | Where-Object Code -EQ 'avm.bicep.compile')
        $compiledErrors.Count | Should -Be 3
        $result.CompiledFiles | Should -Be 2
        @($compiledErrors | Where-Object { $_.File -match '^tests/e2e/[^/]+/main\.test\.bicep$' }).Count |
            Should -Be 3
        $result.Status | Should -Be 'fail'
    }

    It 'accepts both CRLF and LF line endings in test sources' {
        $testPath = Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep'
        $source = [System.IO.File]::ReadAllText($testPath)
        [System.IO.File]::WriteAllText($testPath, $source.Replace("`r`n", "`n").Replace("`n", "`r`n"))

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Count | Should -Be 0
        $result.Status | Should -Be 'pass'
    }

    It 'does not report a false success when the module does not have a registry layout' {
        $outside = Join-Path $TestDrive 'standalone'
        New-Item -ItemType Directory -Path $outside | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'main.bicep') -Value "metadata name = 'Standalone'"

        $result = Invoke-AvmCheckConvention -Path $outside -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.scope'
    }

    It 'requires a top-level main.bicep even when only metadata and another Bicep file remain' {
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'main.bicep')
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'main.json')
        Set-Content -LiteralPath (Join-Path $script:modulePath 'metadata.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:modulePath 'helper.bicep') -Value "metadata name = 'Helper'"

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.required-source'
    }

    It 'checks resource root folder naming without rejecting plurals: <Case>' -TestCases @(
        @{ Case = 'singular'; FolderName = 'widget'; Valid = $true }
        @{ Case = 'plural'; FolderName = 'widgets'; Valid = $true }
        @{ Case = 'plural hyphenated'; FolderName = 'storage-accounts'; Valid = $true }
        @{ Case = 'camel case'; FolderName = 'widgetStore'; Valid = $false }
        @{ Case = 'uppercase'; FolderName = 'WidgetStore'; Valid = $false }
        @{ Case = 'underscore'; FolderName = 'widget_store'; Valid = $false }
        @{ Case = 'existing double hyphen'; FolderName = 'widget--store'; Valid = $true }
    ) {
        param($Case, $FolderName, $Valid)

        if ($FolderName -cne 'widget') {
            Rename-Item -LiteralPath $script:modulePath -NewName $FolderName
            $script:modulePath = Join-Path (Split-Path $script:modulePath -Parent) $FolderName
        }
        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $names = @($result.Issues | Where-Object Code -EQ 'avm.bicep.resource-folder-name')
        if ($Valid) {
            $names.Count | Should -Be 0
        }
        else {
            $names.Count | Should -Be 1
            $names[0].File | Should -Be 'main.bicep'
            $names[0].Severity | Should -Be 'error'
        }
    }

    It 'applies the same naming rule to resource children: <Case>' -TestCases @(
        @{ Case = 'plural'; FolderName = 'children'; Valid = $true }
        @{ Case = 'existing double hyphen'; FolderName = 'configuration--customdnssuffix'; Valid = $true }
        @{ Case = 'uppercase'; FolderName = 'ChildName'; Valid = $false }
        @{ Case = 'underscore'; FolderName = 'child_name'; Valid = $false }
    ) {
        param($Case, $FolderName, $Valid)

        $child = Join-Path $script:modulePath 'child'
        Rename-Item -LiteralPath $child -NewName $FolderName
        $child = Join-Path $script:modulePath $FolderName
        $scope = InModuleScope 'Avm.Authoring' -Parameters @{ P = $child } {
            param($P)
            Get-AvmBicepConventionScope -Path $P
        }
        $run = Invoke-NativeLayoutFixture -Root $script:workingRoot -Scopes @($scope)
        $run.Summary.Total | Should -Be $run.Expected
        $issues = @($run.Issues)
        $names = @($issues | Where-Object Code -EQ 'avm.bicep.resource-folder-name')
        if ($Valid) {
            $names.Count | Should -Be 0
        }
        else {
            $names.Count | Should -Be 1
            $names[0].File | Should -Be "avm/res/mock/widget/$FolderName/main.bicep"
        }
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
        $passing.Issues.Count | Should -Be 0
        $passing.Status | Should -Be 'pass'

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
        $passing.Issues.Count | Should -Be 0
        $passing.Status | Should -Be 'pass'

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
        $result.Issues.Count | Should -Be 0
        $result.Status | Should -Be 'pass'
    }

    It 'identifies missing files and incorrect README casing in root and child scopes' {
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'child' 'main.json')
        Remove-Item -LiteralPath (Join-Path $script:modulePath 'README.md')
        Set-Content -LiteralPath (Join-Path $script:modulePath 'Readme.md') -Value '# Wrong case'

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $missing = @($result.Issues | Where-Object Code -EQ 'avm.bicep.required-file')

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

    Context 'Child publishing allowlist' {
        BeforeEach {
            $script:child = Join-Path $script:modulePath 'child'
            $script:allowlistPath = Join-Path $script:workingRoot `
                '.avm/child-module-publish-allowed-list.json'
            [System.IO.File]::WriteAllText((Join-Path $script:child 'version.json'), '{"version":"0.1"}')
            $changelog = [System.IO.File]::ReadAllText((Join-Path $script:modulePath 'CHANGELOG.md'))
            [System.IO.File]::WriteAllText((Join-Path $script:child 'CHANGELOG.md'),
                $changelog.Replace('widget/CHANGELOG.md', 'widget/child/CHANGELOG.md'))
        }

        It 'accepts a versioned child on the checkout allowlist' {
            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck

            $result.Issues.Count | Should -Be 0
            $result.Status | Should -Be 'pass'
            $result.UncoveredFamilies | Should -Not -Contain 'resource-folder singularization beyond naming syntax'
        }

        It 'runs independent native child file, configuration and approval requirements' {
            $run = InModuleScope 'Avm.Authoring' -Parameters @{
                Path = $script:child; Root = $script:workingRoot
            } {
                param($Path, $Root)
                $data = @{
                    RepositoryRoot = $Root
                    ChildPublishInput = Get-AvmBicepChildPublishInput -RepositoryRoot $Root `
                        -Scopes @((Get-AvmBicepConventionScope -Path $Path))
                }
                $suite = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Resources' 'bicep' 'conventions' 'ChildPublish.Tests.ps1'
                $summary = Invoke-AvmBicepPesterSuite -Files @($suite) -WorkingDirectory $Root `
                    -Mode Convention -ConventionData $data -EnvVars @{} -InProcess
                @{ Summary = $summary; Expected = $data.NativeChildPublishExpected }
            }
            $run.Expected | Should -Be 3
            $run.Summary.Total | Should -Be 3
            $run.Summary.Passed | Should -Be 3
            @($run.Summary.Issues) | Should -HaveCount 0
        }

        It 'does not fall back to the old registry utility approval file' {
            $legacy = Join-Path $script:workingRoot 'utilities' 'pipelines' 'staticValidation' 'compliance' 'helper'
            $null = New-Item -ItemType Directory -Path $legacy -Force
            Move-Item -LiteralPath $script:allowlistPath -Destination $legacy
            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            $result.Status | Should -Be 'fail'
            $result.Issues.Code | Should -Contain 'avm.bicep.child-publish-allowlist'
        }

        It 'rejects a versioned child absent from the current checkout allowlist' {
            [System.IO.File]::WriteAllText(
                $script:allowlistPath, '{"allowed-child-modules":["avm/res/mock/widget/other"]}')

            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            $issue = @($result.Issues | Where-Object Code -EQ 'avm.bicep.child-publish-not-allowed')
            $issue.Count | Should -Be 1
            $issue[0].File | Should -Be 'avm/res/mock/widget/child/version.json'
            $issue[0].Message | Should -Match 'avm/res/mock/widget/child'
        }

        It 'requires the authoritative allowlist when any child is versioned' {
            Remove-Item -LiteralPath $script:allowlistPath

            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            $issue = @($result.Issues | Where-Object Code -EQ 'avm.bicep.child-publish-allowlist')
            $issue.Count | Should -Be 1
            $issue[0].File | Should -Be (
                '.avm/child-module-publish-allowed-list.json')
            $issue[0].Message | Should -Match 'Versioned children cannot be approved'

            Remove-Item -LiteralPath (Join-Path $script:child 'version.json')
            Remove-Item -LiteralPath (Join-Path $script:child 'CHANGELOG.md')
            $unversioned = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            @($unversioned.Issues | Where-Object Code -Like 'avm.bicep.child-publish-*').Count |
                Should -Be 0
        }

        It 'rejects invalid checkout allowlists: <Case>' -TestCases @(
            @{ Case = 'malformed JSON'; Content = '{' }
            @{ Case = 'missing array'; Content = '{}' }
            @{ Case = 'wrong shape'; Content = '{"allowed-child-modules":"avm/res/mock/widget/child"}' }
            @{ Case = 'path escape'; Content = '{"allowed-child-modules":["avm/res/mock/widget/../child"]}' }
            @{ Case = 'wrong case'; Content = '{"allowed-child-modules":["avm/res/mock/widget/Child"]}' }
            @{ Case = 'trailing newline'; Content = '{"allowed-child-modules":["avm/res/mock/widget/child\n"]}' }
            @{ Case = 'duplicate path'; Content = '{"allowed-child-modules":["avm/res/mock/widget/child","avm/res/mock/widget/child"]}' }
        ) {
            param($Case, $Content)

            [System.IO.File]::WriteAllText($script:allowlistPath, $Content)
            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck

            @($result.Issues | Where-Object Code -EQ 'avm.bicep.child-publish-allowlist').Count |
                Should -Be 1
            $result.Issues.Code | Should -Not -Contain 'avm.bicep.child-publish-not-allowed'
        }

        It 'fails with a named error on unreadable UTF-8 in the allowlist' {
            [System.IO.File]::WriteAllBytes($script:allowlistPath, [byte[]]@(0xC3, 0x28))
            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            $result.Issues.Code | Should -Contain 'avm.bicep.child-publish-allowlist'
        }

        It 'rejects the wrong casing of an allowlist directory on Windows and Linux' {
            Rename-Item -LiteralPath (Split-Path $script:allowlistPath -Parent) -NewName '.Avm'
            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            $result.Issues.Code | Should -Contain 'avm.bicep.child-publish-allowlist'
        }

        It 'does not trust a mis-cased child version filename' {
            Rename-Item -LiteralPath (Join-Path $script:child 'version.json') -NewName 'Version.json'
            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            $result.Issues.Code | Should -Contain 'avm.bicep.child-publish-version-file'
        }

        It 'still checks the allowlist when repository-wide test discovery fails first' {
            InModuleScope 'Avm.Authoring' {
                Mock Get-AvmBicepRepositoryTestFile {
                    throw [System.UnauthorizedAccessException]::new('Fixture directory is unreadable.')
                }
            }
            Rename-Item -LiteralPath (Split-Path $script:allowlistPath -Parent) -NewName '.Avm'

            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            $result.Issues.Code | Should -Contain 'avm.bicep.test-discovery'
            $result.Issues.Code | Should -Contain 'avm.bicep.child-publish-allowlist'
            $result.Status | Should -Be 'fail'
        }
    }

    It 'rejects a noncanonical scope path ending in a newline rather than truncating its identity' {
        if ($IsWindows) {
            Set-ItResult -Skipped -Because 'Windows rejects control characters in filesystem paths.'
            return
        }
        $path = Join-Path $script:modulePath "child`n"
        $scope = InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P)
            Get-AvmBicepConventionScope -Path $P
        }
        $scope | Should -BeNullOrEmpty
    }

    Context 'Publication-aware changelogs and parent versions' {
        It 'allows a published older release next to the pending target version' {
            $path = Join-Path $script:modulePath 'CHANGELOG.md'
            $existing = [System.IO.File]::ReadAllText($path)
            $older = "`n## 0.0.1`n`n### Changes`n`n- Previous`n`n### Breaking Changes`n`n- None`n"
            [System.IO.File]::WriteAllText($path, $existing + $older)
            InModuleScope 'Avm.Authoring' {
                Mock Invoke-WebRequest {
                    [pscustomobject]@{
                        StatusCode   = 200
                        Content      = '{"name":"bicep/avm/res/mock/widget","tags":["0.0.1"]}'
                        Headers      = @{}
                        BaseResponse = [pscustomobject]@{
                            RequestMessage = [pscustomobject]@{ RequestUri = $Uri }
                        }
                    }
                }
            }

            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            @($result.Issues | Where-Object {
                    $_.Code -like 'avm.bicep.changelog-unpublished*' -or
                    $_.Code -like 'avm.bicep.changelog-target*'
                }).Count | Should -Be 0
            $result.Status | Should -Be 'pass'
        }

        It 'reports unpublished headings and a missing next target section with file-specific codes' {
            $path = Join-Path $script:modulePath 'CHANGELOG.md'
            $text = [System.IO.File]::ReadAllText($path)
            [System.IO.File]::WriteAllText($path, $text.Replace('## 0.1.0', '## 0.2.0'))

            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            $unpublished = @($result.Issues | Where-Object Code -EQ 'avm.bicep.changelog-unpublished-version')
            $unpublished.Count | Should -Be 1
            $unpublished[0].File | Should -Be 'avm/res/mock/widget/CHANGELOG.md'
            $unpublished[0].Line | Should -BeGreaterThan 0
            $result.Issues.Code | Should -Contain 'avm.bicep.changelog-target-version'
        }

        It 'accepts an initial version only after an exact MCR not-found response' {
            InModuleScope 'Avm.Authoring' {
                Mock Invoke-WebRequest {
                    [pscustomobject]@{
                        StatusCode   = 404
                        Content      = '{"errors":[{"code":"NAME_UNKNOWN"}]}'
                        Headers      = @{}
                        BaseResponse = [pscustomobject]@{
                            RequestMessage = [pscustomobject]@{ RequestUri = $Uri }
                        }
                    }
                }
            }
            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            @($result.Issues | Where-Object {
                    $_.Code -like 'avm.bicep.published-tags-*' -or
                    $_.Code -like 'avm.bicep.changelog-*'
                }).Count | Should -Be 0
        }

        It 'fails closed when MCR is unavailable rather than treating tags as empty' {
            InModuleScope 'Avm.Authoring' {
                Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('MCR unavailable') }
                Mock Wait-AvmRetryDelay { }
            }
            $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
            $issue = @($result.Issues | Where-Object Code -EQ 'avm.bicep.published-tags-unavailable')
            $issue.Count | Should -Be 1
            $issue[0].File | Should -Be 'avm/res/mock/widget/CHANGELOG.md'
            $result.Status | Should -Be 'fail'
        }

        It 'fails closed without MCR or Git calls when offline' {
            $original = $env:AVM_OFFLINE
            try {
                $env:AVM_OFFLINE = '1'
                $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
                $result.Issues.Code | Should -Contain 'avm.bicep.published-tags-offline'
                InModuleScope 'Avm.Authoring' {
                    Should -Invoke Invoke-WebRequest -Exactly 0
                    Should -Invoke Get-AvmBicepPublicationGitState -Exactly 0
                }
            }
            finally {
                if ($null -eq $original) {
                    Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
                }
                else {
                    $env:AVM_OFFLINE = $original
                }
            }
        }

        Context 'Changed established child' {
            BeforeEach {
                $script:childPath = Join-Path $script:modulePath 'child'
                [System.IO.File]::WriteAllText(
                    (Join-Path $script:childPath 'version.json'), '{"version":"0.2"}')
                $changelog = [System.IO.File]::ReadAllText((Join-Path $script:modulePath 'CHANGELOG.md'))
                [System.IO.File]::WriteAllText(
                    (Join-Path $script:childPath 'CHANGELOG.md'),
                    $changelog.Replace('widget/CHANGELOG.md', 'widget/child/CHANGELOG.md').
                    Replace('## 0.1.0', '## 0.2.0'))
                InModuleScope 'Avm.Authoring' {
                    Mock Get-AvmBicepPublicationTargetVersion {
                        if ($Scope.ModuleRelativePath.EndsWith('/child')) {
                            return [pscustomobject]@{
                                TargetVersion = '0.2.0'; VersionChanged = $true
                                PreviousVersion = '0.1'; ShouldPublish = $true
                            }
                        }
                        [pscustomobject]@{
                            TargetVersion = '0.1.1'; VersionChanged = $false
                            PreviousVersion = '0.1'; ShouldPublish = $true
                        }
                    }
                    Mock Invoke-WebRequest {
                        $name = $Uri.AbsolutePath.Substring(4).Replace('/tags/list', '')
                        [pscustomobject]@{
                            StatusCode   = 200
                            Content      = '{"name":"' + $name + '","tags":["0.1.0"]}'
                            Headers      = @{}
                            BaseResponse = [pscustomobject]@{
                                RequestMessage = [pscustomobject]@{ RequestUri = $Uri }
                            }
                        }
                    }
                }
            }

            It 'requires the versioned parent to increment when the child resets to a new minor' {
                $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
                $issue = @($result.Issues | Where-Object Code -EQ 'avm.bicep.parent-version-not-increased')
                $issue.Count | Should -Be 1
                $issue[0].File | Should -Be 'avm/res/mock/widget/version.json'
                $issue[0].Message | Should -Match 'avm/res/mock/widget/child'
            }

            It 'accepts a parent increase and matching target changelogs' {
                [System.IO.File]::WriteAllText(
                    (Join-Path $script:modulePath 'version.json'), '{"version":"0.2"}')
                $path = Join-Path $script:modulePath 'CHANGELOG.md'
                [System.IO.File]::WriteAllText(
                    $path, [System.IO.File]::ReadAllText($path).Replace('## 0.1.0', '## 0.2.0'))
                InModuleScope 'Avm.Authoring' {
                    Mock Get-AvmBicepPublicationTargetVersion {
                        [pscustomobject]@{
                            TargetVersion = '0.2.0'; VersionChanged = $true
                            PreviousVersion = '0.1'; ShouldPublish = $true
                        }
                    }
                }
                $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
                $result.Issues.Count | Should -Be 0
                $result.Status | Should -Be 'pass'
            }
        }
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
        @($result.Issues | Where-Object Code -EQ 'avm.bicep.changelog-section').Line[0] |
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
        $result.Issues.Count | Should -Be 0
        $result.Status | Should -Be 'pass'
    }

    It 'detects duplicate serviceShort values in another module of the repository' {
        $other = Join-Path $script:workingRoot 'avm' 'ptn' 'mock' 'other' 'tests' 'e2e' 'defaults'
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep') `
            -Destination (Join-Path $other 'main.test.bicep')

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $duplicates = @($result.Issues | Where-Object Code -EQ 'avm.bicep.test-service-short-duplicate')
        $duplicates.Count | Should -Be 1
        $duplicates[0].Message | Should -Match 'avm/ptn/mock/other/tests/e2e/defaults/main.test.bicep'
    }

    It 'detects duplicate serviceShort values outside avm/' {
        $other = Join-Path $script:workingRoot 'other' 'tests'
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep') `
            -Destination (Join-Path $other 'main.test.bicep')

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $duplicates = @($result.Issues | Where-Object Code -EQ 'avm.bicep.test-service-short-duplicate')
        $duplicates.Count | Should -Be 1
        $duplicates[0].Message | Should -Match 'other/tests/main.test.bicep'
    }

    It 'checks required test folders for each scope and rejects a versioned multi-scope parent' {
        Copy-Item -LiteralPath (Join-Path $script:modulePath 'child') `
            -Destination (Join-Path $script:modulePath 'rg-scope') -Recurse

        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck
        $result.Issues.Code | Should -Contain 'avm.bicep.multiscope-version'
        @($result.Issues | Where-Object Code -EQ 'avm.bicep.scope-test-missing').Count | Should -Be 2
        $result.Issues.Code | Should -Contain 'avm.bicep.test-scope-reference'
    }

    It 'fails closed when packaged PSRule configuration is unavailable' {
        InModuleScope Avm.Authoring {
            Mock Import-AvmBicepPolicyModule {
                [pscustomobject]@{ Name = 'fixture'; Path = 'fixture' }
            }
            Mock Get-AvmBicepPolicyConfiguration {
                throw [AvmConfigurationException]::new('The installed package is missing its policy configuration.')
            }
        }
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.ToolSource | Should -Be 'not-run'
        $result.RequiredBaselines | Should -Be @('Azure.Pillar.Reliability', 'CB.AVM.WAF.Security')
        $result.AdvisoryBaselines | Should -Be @('Azure.Default', 'Azure.Pillar.Security')
        $result.Issues[0].Code | Should -Be 'avm.bicep.psrule-config'
    }
}
