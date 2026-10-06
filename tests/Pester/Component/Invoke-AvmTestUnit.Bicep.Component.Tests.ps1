#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $manifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    . (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') -SourceManifest $manifest

    $script:root = Join-Path $TestDrive 'bicep unit module'
    $unit = Join-Path $script:root 'tests' 'unit'
    $null = New-Item -ItemType Directory -Path $unit -Force
    Set-Content -LiteralPath (Join-Path $script:root 'main.bicep') `
        -Value 'param name string' -Encoding utf8NoBOM

    $source = @'
Describe 'Bicep module' {
    It 'passes' -Tag 'fast' {
        $global:AvmBicepUnitChildMarker = 'child-only'
        $true | Should -BeTrue
    }
    It 'fails' -Tag 'failure' { $true | Should -BeFalse }
    It 'skips' -Tag 'skip' -Skip { $true | Should -BeTrue }
}
'@
    Set-Content -LiteralPath (Join-Path $unit 'smoke.tests.ps1') -Value $source -Encoding utf8NoBOM
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep Pester unit tier' -Tag 'Component' {
    It 'executes selected tests in a child process and reports excluded tests separately' {
        $result = Invoke-AvmTestUnit -Path $script:root -Tag 'fast'

        $result.Status | Should -Be 'pass'
        $result.Engine | Should -Be 'bicep'
        $result.UnitFiles | Should -Be 1
        $result.ComplianceFile | Should -BeNullOrEmpty
        $result.ModuleScopes | Should -Be 1
        $result.RunsTotal | Should -Be 1
        $result.RunsPassed | Should -Be 1
        $result.RunsFiltered | Should -Be 2
        $result.Issues | Should -BeNullOrEmpty
        Get-Variable -Name AvmBicepUnitChildMarker -Scope Global -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'filters by Pester full name and reports no match as skipped, not passed' {
        $selected = Invoke-AvmTestUnit -Path $script:root -TestName '*.passes'
        $selected.Status | Should -Be 'pass'
        $selected.RunsPassed | Should -Be 1

        $empty = Invoke-AvmTestUnit -Path $script:root -Tag 'does-not-exist'
        $empty.Status | Should -Be 'skipped'
        $empty.RunsTotal | Should -Be 0
        $empty.RunsFiltered | Should -Be 3
    }

    It 'surfaces failed and explicitly skipped tests as failures' {
        $failed = Invoke-AvmTestUnit -Path $script:root -Tag 'failure'
        $failed.Status | Should -Be 'fail'
        $failed.RunsFailed | Should -Be 1
        $failed.Issues[0].Message | Should -Match 'Expected'

        $skipped = Invoke-AvmTestUnit -Path $script:root -Tag 'skip'
        $skipped.Status | Should -Be 'fail'
        $skipped.RunsSkipped | Should -Be 1
        $skipped.Issues[0].Code | Should -Be 'avm.bicep.pester-skipped'
    }

    It 'includes nested module unit tests only with -Recurse' {
        $child = Join-Path $script:root 'child'
        $childUnit = Join-Path $child 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $childUnit -Force
        Set-Content -LiteralPath (Join-Path $child 'main.bicep') `
            -Value 'param child string' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $childUnit 'child.tests.ps1') `
            -Value "Describe 'Child' { It 'passes' -Tag fast { `$true | Should -BeTrue } }" `
            -Encoding utf8NoBOM

        $default = Invoke-AvmTestUnit -Path $script:root -Tag 'fast'
        $default.ModuleScopes | Should -Be 1
        $default.RunsPassed | Should -Be 1

        $recursive = Invoke-AvmTestUnit -Path $script:root -Tag 'fast' -Recurse
        $recursive.Status | Should -Be 'pass'
        $recursive.ModuleScopes | Should -Be 2
        $recursive.UnitFiles | Should -Be 2
        $recursive.RunsPassed | Should -Be 2
    }

    It 'passes scope and repository data to an explicit compliance suite' {
        $compliance = Join-Path $TestDrive 'module.tests.ps1'
        $source = @'
param([array] $moduleFolderPaths, [string] $repoRootPath)
Describe 'Compliance' {
    It 'receives the selected scope' -Tag 'scope' {
        $moduleFolderPaths.Count | Should -Be 1
        $moduleFolderPaths[0] | Should -Be $repoRootPath
    }
}
'@
        Set-Content -LiteralPath $compliance -Value $source -Encoding utf8NoBOM
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $script:root; Suite = $compliance } {
            param($Root, $Suite)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'pinned'; Path = [Environment]::ProcessPath; Source = 'cache' }
            }
            Invoke-AvmTestUnit -Path $Root -Tag 'scope' -CompliancePath $Suite -RepositoryRoot $Root
        }
        $result.Status | Should -Be 'pass'
        $result.ComplianceFile | Should -Be $compliance
        $result.RunsPassed | Should -Be 1
        $result.UnitFiles | Should -Be 1
        $result.FilesProcessed | Should -Be 2
    }

    It 'does not run a discoverable registry compliance suite by default' {
        $suite = Join-Path -Path $script:root -ChildPath 'utilities' `
            -AdditionalChildPath 'pipelines', 'staticValidation', 'compliance', 'module.tests.ps1'
        $null = New-Item -ItemType Directory -Path (Split-Path $suite) -Force
        Set-Content -LiteralPath $suite -Value @'
Describe 'Compliance' {
    It 'fails if run by default' -Tag 'fast' { $true | Should -BeFalse }
}
'@ -Encoding utf8NoBOM
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $script:root } {
            param($Root)
            Mock Resolve-AvmTool { throw 'Default unit tests must not resolve a Bicep compiler' }
            Invoke-AvmTestUnit -Path $Root -RepositoryRoot $Root -Tag 'fast'
        }
        $result.Status | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 1
        $result.ComplianceFile | Should -BeNullOrEmpty
        $result.RunsPassed | Should -Be 1
    }

    It 'retains a registry suite as an explicit compliance override' {
        $suite = Join-Path -Path $script:root -ChildPath 'utilities' `
            -AdditionalChildPath 'pipelines', 'staticValidation', 'compliance', 'module.tests.ps1'
        $null = New-Item -ItemType Directory -Path (Split-Path $suite) -Force
        Set-Content -LiteralPath $suite -Value @'
param([array] $moduleFolderPaths, [string] $repoRootPath)
Describe 'Compliance' {
    It 'receives module scopes on opt-in' -Tag 'compliance' {
        $moduleFolderPaths.Count | Should -Be 1
        $moduleFolderPaths[0] | Should -Be $repoRootPath
    }
}
'@ -Encoding utf8NoBOM
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $script:root; Suite = $suite } {
            param($Root, $Suite)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'pinned'; Path = [Environment]::ProcessPath; Source = 'cache' }
            }
            Invoke-AvmTestUnit -Path $Root -RepositoryRoot $Root `
                -IncludeCompliance -CompliancePath $Suite -Tag 'compliance'
        }
        $result.Status | Should -Be 'pass'
        $result.ComplianceFile | Should -Be $suite
        $result.FilesProcessed | Should -Be 2
        $result.RunsPassed | Should -Be 1
    }

    It 'combines isolated authored tests with packaged results without masking failure: <Failure>' -ForEach @(
        @{ Failure = $false }
        @{ Failure = $true }
    ) {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $script:root; Failure = $Failure } {
            param($Root, $Failure)
            $script:complianceFailure = $Failure
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'pinned'; Path = [Environment]::ProcessPath; Source = 'cache' }
            }
            Mock Invoke-AvmBicepPackagedCompliance {
                $issues = @()
                if ($script:complianceFailure) {
                    $issues = @([pscustomobject]@{ File = 'metadata.json'; Line = 1; Code = 'AVM_METADATA_SCHEMA'; Severity = 'error'; Message = 'Invalid metadata.' })
                }
                [pscustomobject]@{
                    Suite = 'packaged'
                    Issues = $issues
                    Summary = @{
                        Version = 'fixture'; Total = 2; Passed = 2 - [int]$script:complianceFailure
                        Failed = [int]$script:complianceFailure; Skipped = 0; Inconclusive = 0; Filtered = 0
                    }
                }
            }
            Invoke-AvmTestUnit -Path $Root -IncludeCompliance -Tag fast
        }
        $result.Status | Should -Be $(if ($Failure) { 'fail' } else { 'pass' })
        $result.RunsTotal | Should -Be 3
        $result.RunsPassed | Should -Be (3 - [int]$Failure)
        $result.RunsFailed | Should -Be ([int]$Failure)
        $result.UnitFiles | Should -Be 1
        $result.FilesProcessed | Should -Be 2
        Get-Variable -Name AvmBicepUnitChildMarker -Scope Global -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'returns skipped without starting Pester when no test suite exists' {
        $root = Join-Path $TestDrive 'empty-bicep'
        $null = New-Item -ItemType Directory -Path $root -Force
        Set-Content -LiteralPath (Join-Path $root 'main.bicep') -Value 'param x string' -Encoding utf8NoBOM

        $result = Invoke-AvmTestUnit -Path $root
        $result.Status | Should -Be 'skipped'
        $result.FilesProcessed | Should -Be 0
        $result.RunsTotal | Should -Be 0
    }

    It 'does not require monorepo compliance unless explicitly requested' {
        $root = Join-Path $TestDrive 'registry-without-compliance'
        $modulePath = Join-Path $root 'avm' 'res' 'storage' 'sample'
        $null = New-Item -ItemType Directory -Path $modulePath -Force
        Set-Content -LiteralPath (Join-Path $root 'bicepconfig.json') -Value '{}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $modulePath 'main.bicep') `
            -Value 'param x string' -Encoding utf8NoBOM
        $unit = Join-Path $modulePath 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $unit -Force
        Set-Content -LiteralPath (Join-Path $unit 'module.tests.ps1') `
            -Value "Describe 'Monorepo unit' { It 'passes' { `$true | Should -BeTrue } }" `
            -Encoding utf8NoBOM

        $default = Invoke-AvmTestUnit -Path $root
        $default.Status | Should -Be 'pass'
        $default.UnitFiles | Should -Be 1
        $default.RunsPassed | Should -Be 1
        $default.ComplianceFile | Should -BeNullOrEmpty
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Mock Invoke-AvmBicepPackagedCompliance { throw 'Packaged compliance selected' }
            { Invoke-AvmTestUnit -Path $Root -IncludeCompliance } |
                Should -Throw -ExpectedMessage '*Packaged compliance selected*'
        }
    }

    It 'rejects wrong-case Bicep entry point and test directories' {
        $root = Join-Path $TestDrive 'wrong-case-bicep'
        $null = New-Item -ItemType Directory -Path $root -Force
        Set-Content -LiteralPath (Join-Path $root 'Main.Bicep') -Value 'param x string' -Encoding utf8NoBOM
        $context = [pscustomobject]@{ Kind = 'bicep-module'; Root = $root; Ecosystem = 'bicep' }
        $thrown = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $context } {
                param($C)
                Get-AvmBicepTestScope -Context $C | Out-Null
            }
        }
        catch {
            $thrown = $_.Exception
        }
        $thrown.GetType().Name | Should -Be 'AvmConfigurationException'
        $thrown.Message | Should -Match 'exact casing'
    }
}
