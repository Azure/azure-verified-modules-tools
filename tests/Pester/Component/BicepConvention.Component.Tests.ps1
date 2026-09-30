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
    }

    It 'checks the complete root and child fixture and reports only the known coverage gap' {
        $result = Invoke-AvmCheckConvention -Path $script:modulePath -SkipModuleVersionCheck

        $result.Engine | Should -Be 'bicep'
        $result.Status | Should -Be 'fail'
        $result.ScopesChecked | Should -Be 2
        $result.UncoveredFamilies.Count | Should -Be 5
        $result.Issues.Count | Should -Be 1
        $result.Issues[0].Code | Should -Be 'avm.bicep.convention-incomplete'
        $result.Issues[0].Severity | Should -Be 'error'
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

    It 'reports policy coverage and all required and advisory baselines without claiming PSRule ran' {
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck

        $result.Status | Should -Be 'fail'
        $result.ToolSource | Should -Be 'not-run'
        $result.RequiredBaselines | Should -Be @('Azure.Pillar.Reliability', 'CB.AVM.WAF.Security')
        $result.AdvisoryBaselines | Should -Be @('Azure.Default', 'Azure.Pillar.Security')
        $result.Issues[0].Code | Should -Be 'avm.bicep.psrule-incomplete'
    }
}
