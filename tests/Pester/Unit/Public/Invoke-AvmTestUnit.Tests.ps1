#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTestUnit' {
    It 'reports <Ecosystem> diagnostics once in <HostName> without changing results' -ForEach @(
        @{ Ecosystem = 'bicep'; HostName = 'local'; Actions = $false }
        @{ Ecosystem = 'bicep'; HostName = 'Actions'; Actions = $true }
        @{ Ecosystem = 'terraform'; HostName = 'local'; Actions = $false }
        @{ Ecosystem = 'terraform'; HostName = 'Actions'; Actions = $true }
    ) {
        $savedActions = [Environment]::GetEnvironmentVariable('GITHUB_ACTIONS')
        $savedSummary = [Environment]::GetEnvironmentVariable('GITHUB_STEP_SUMMARY')
        try {
            $env:GITHUB_ACTIONS = if ($Actions) { 'true' } else { '' }
            $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive "$Ecosystem-$HostName.md"
            InModuleScope 'Avm.Authoring' -Parameters @{ Eco = $Ecosystem; IsActions = $Actions; Root = $TestDrive } {
                param($Eco, $IsActions, $Root)
                Mock Test-AvmModuleVersion {}
                Mock Get-AvmModuleContextInternal {
                    [pscustomobject]@{ Root = $Root; Ecosystem = $Eco }
                }
                Mock Invoke-AvmBicepTestUnit {
                    [pscustomobject]@{ Status = 'fail'; Issues = @(
                            [pscustomobject]@{ Severity = 'warning'; Code = 'warn'; File = 'main.bicep'; Line = 2; Message = 'unit warning' }
                            [pscustomobject]@{ Severity = 'error'; Code = 'err'; File = 'main.bicep'; Line = 3; Message = "Expected 'secret', got 'other'." }
                            [pscustomobject]@{ Severity = 'info'; Code = 'info'; Message = "Expected 'secret'." }
                        ) }
                }
                Mock Invoke-AvmTerraformTestSuite {
                    [pscustomobject]@{ Status = 'fail'; Issues = @(
                            [pscustomobject]@{ Severity = 'warning'; Code = 'warn'; File = 'main.tf'; Line = 2; Message = 'unit warning' }
                            [pscustomobject]@{ Severity = 'error'; Code = 'err'; File = 'main.tf'; Line = 3; Message = 'unit error' }
                        ) }
                }
                $output = @(Invoke-AvmTestUnit 3>&1 6>&1)
                $result = @($output | Where-Object { $_.PSObject.Properties['Status'] })[0]
                $result.Status | Should -Be 'fail'
                $result.Issues | Should -HaveCount $(if ($Eco -eq 'bicep') { 3 } else { 2 })
                $messages = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] -or
                            $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { [string]$_ })
                @($messages | Where-Object { $_ -match '\[warn\] unit warning' }) | Should -HaveCount 1
                @($messages | Where-Object { $_ -match '\[err\]' }) | Should -HaveCount 1
                if ($Eco -eq 'bicep') {
                    $result.Issues[1].Message | Should -Match 'secret'
                    ($messages -join "`n") | Should -Not -Match 'secret|other'
                    @($messages | Where-Object { $_ -match '\[info\] Expected <value>' }) | Should -HaveCount 1
                }
                if ($IsActions) {
                    @($messages | Where-Object { $_ -match '^::warning file=.*line=2::' }) | Should -HaveCount 1
                    @($messages | Where-Object { $_ -match '^::error file=.*line=3::' }) | Should -HaveCount 1
                    $summary = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
                    $summary | Should -Match 'unit warning'
                    $summary | Should -Not -Match 'secret|other'
                }
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS',
                $(if ($null -eq $savedActions) { [NullString]::Value } else { $savedActions }))
            [Environment]::SetEnvironmentVariable('GITHUB_STEP_SUMMARY',
                $(if ($null -eq $savedSummary) { [NullString]::Value } else { $savedSummary }))
        }
    }

    It 'does not repeat unit diagnostics in dispatcher output' {
        InModuleScope 'Avm.Authoring' {
            Mock Test-AvmModuleVersion {}
            Mock Get-AvmModuleContextInternal { [pscustomobject]@{ Root = $PWD.Path; Ecosystem = 'terraform' } }
            Mock Invoke-AvmTerraformTestSuite {
                [pscustomobject]@{ Status = 'fail'; Issues = @(
                        [pscustomobject]@{ Severity = 'error'; Code = 'unit-error'; Message = 'failed assertion' }
                    ) }
            }
            $messages = @(& { try { avm test unit 6>&1 } catch { } } | ForEach-Object { [string]$_ })
            @($messages | Where-Object { $_ -match 'failed assertion' }) | Should -HaveCount 1
        }
    }

    It 'is wired into the verb registry as "avm test unit"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 2 -and $_.Path[0] -eq 'test' -and $_.Path[1] -eq 'unit' }
        $entry        | Should -Not -BeNullOrEmpty
        $entry.Cmdlet | Should -Be 'Invoke-AvmTestUnit'
    }

    It 'passes the explicit source-preview version opt-out into real module context resolution' {
        $dir = Join-Path $TestDrive ('unit-version-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        [System.IO.File]::WriteAllText((Join-Path $dir 'main.tf'), "terraform {}`n")

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Test-AvmModuleVersion {
                if (-not $SkipModuleVersionCheck) {
                    throw [System.InvalidOperationException]::new('A nested Gallery version check was not skipped.')
                }
            }
            Mock Invoke-AvmTerraformTestSuite { [pscustomobject]@{ Status = 'pass' } }
            $run = Invoke-AvmTestUnit -Path $D -Ecosystem terraform -SkipModuleVersionCheck
            Should -Invoke Test-AvmModuleVersion -Exactly 1 -ParameterFilter { $SkipModuleVersionCheck }
            $run
        }

        $result.Status | Should -Be 'pass'
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformTestSuite with -Tier unit' {
        $dir = Join-Path $TestDrive ("tf-unit-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContextInternal { $ctx }
            Mock Invoke-AvmTerraformTestSuite {
                param($Context, $Tier)
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; Tier = $Tier; FilesProcessed = 1; Issues = @() }
            }
            Invoke-AvmTestUnit -Path $D
        }
        $result.Engine | Should -Be 'terraform'
        $result.Tier   | Should -Be 'unit'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTerraformTestSuite -Exactly 1 -ParameterFilter { $Tier -eq 'unit' }
        }
    }

    It 'dispatches a bicep context and forwards the Pester selection' {
        $dir = Join-Path $TestDrive ("bicep-unit-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContextInternal { $ctx }
            Mock Invoke-AvmTerraformTestSuite { throw 'should not be called' }
            Mock Invoke-AvmBicepTestUnit {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; RunsPassed = 1; Issues = @() }
            }
            $result = Invoke-AvmTestUnit -Path $D -Tag 'UDT' -TestName '*parameter*' `
                -Recurse -CompliancePath 'module.tests.ps1' -RepositoryRoot $D
            $result.Engine | Should -Be 'bicep'
            $result.RunsPassed | Should -Be 1
            Should -Invoke Invoke-AvmBicepTestUnit -Exactly 1 -ParameterFilter {
                $Tag[0] -eq 'UDT' -and $TestName[0] -eq '*parameter*' -and $Recurse -and
                $CompliancePath -eq 'module.tests.ps1' -and $RepositoryRoot -eq $D -and
                -not $IncludeCompliance.IsPresent
            }
            Should -Invoke Invoke-AvmTerraformTestSuite -Times 0 -Exactly
        }
    }

    It 'forwards an explicit compliance opt-in and rejects an empty suite path' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'bicep-module'; Root = 'module'; Ecosystem = 'bicep' }
            }
            Mock Invoke-AvmBicepTestUnit {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' }
            }
            Invoke-AvmTestUnit -IncludeCompliance | Out-Null
            Should -Invoke Invoke-AvmBicepTestUnit -Exactly 1 -ParameterFilter {
                $IncludeCompliance.IsPresent
            }
            { Invoke-AvmTestUnit -CompliancePath '' } |
                Should -Throw -ExpectedMessage '*CompliancePath cannot be empty*'
            Should -Invoke Invoke-AvmBicepTestUnit -Exactly 1
        }
    }

    It 'rejects options belonging to the other ecosystem instead of ignoring them' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'bicep-module'; Root = 'module'; Ecosystem = 'bicep' }
            }
            { Invoke-AvmTestUnit -NoInit } |
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*Terraform*'

            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'terraform-module-repo'; Root = 'module'; Ecosystem = 'terraform' }
            }
            { Invoke-AvmTestUnit -Tag 'unit' } |
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*Bicep*'
            { Invoke-AvmTestUnit -IncludeCompliance } |
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*Bicep*'
        }
    }

    It 'forwards -Ecosystem to Get-AvmModuleContextInternal' {
        $dir = Join-Path $TestDrive ("eco-fwd-unit-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $script:eco = $null
            Mock Get-AvmModuleContextInternal {
                param($Path, $Ecosystem)
                $script:eco = $Ecosystem
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmTerraformTestSuite {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 0; Issues = @() }
            }
            Invoke-AvmTestUnit -Path $D -Ecosystem 'terraform' | Out-Null
            $script:eco | Should -Be 'terraform'
        }
    }
}
