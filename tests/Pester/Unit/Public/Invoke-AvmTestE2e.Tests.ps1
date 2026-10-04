#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    & (Join-Path $PSScriptRoot '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $script:moduleRoot 'Avm.Authoring.psd1')
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTestE2e' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmTestE2e -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm test e2e"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 2 -and $_.Path[0] -eq 'test' -and $_.Path[1] -eq 'e2e' }
        $entry        | Should -Not -BeNullOrEmpty
        $entry.Cmdlet | Should -Be 'Invoke-AvmTestE2e'
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformTestE2e' {
        $dir = Join-Path $TestDrive ("tf-e2e-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContextInternal { $ctx }
            Mock Invoke-AvmTerraformTestE2e {
                param($Context)
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 1; Issues = @() }
            }
            Invoke-AvmTestE2e -Path $D
        }
        $result.Engine | Should -Be 'terraform'
        $result.Status | Should -Be 'pass'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 1
        }
    }

    It 'forwards -AllowPathFallback to the engine' {
        $dir = Join-Path $TestDrive ("apf-e2e-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContextInternal { $ctx }
            Mock Invoke-AvmTerraformTestE2e {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 0; Issues = @() }
            }
            Invoke-AvmTestE2e -Path $D -AllowPathFallback | Out-Null

            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 1 -ParameterFilter { $AllowPathFallback.IsPresent }
        }
    }

    It 'routes a bicep context and explicit deployment inputs to the Bicep engine' {
        $dir = Join-Path $TestDrive ("bicep-e2e-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContextInternal { $ctx }
            Mock Invoke-AvmTerraformTestE2e { throw 'Terraform must not run' }
            Mock Invoke-AvmBicepTestE2e {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; RunsPassed = 1 }
            }
            $result = Invoke-AvmTestE2e -Path $D -Example 'defaults' -Recurse `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -Location 'westus' -ResourceGroupPrefix 'avm-test' `
                -Tokens @{ namePrefix = 'demo' } -Parameters @{ sku = 'Standard_LRS' } `
                -SkipModuleVersionCheck

            $result.Engine | Should -Be 'bicep'
            Should -Invoke Invoke-AvmBicepTestE2e -Exactly 1 -ParameterFilter {
                $Example[0] -eq 'defaults' -and $Recurse.IsPresent -and
                $SubscriptionId -eq '00000000-0000-0000-0000-000000000001' -and
                $Location -eq 'westus' -and $ResourceGroupPrefix -eq 'avm-test' -and
                $Tokens.namePrefix -eq 'demo' -and $Parameters.sku -eq 'Standard_LRS'
            }
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 0
        }
    }

    It 'rejects ecosystem-specific options before invoking the wrong engine' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Root = '.'; Ecosystem = $Ecosystem }
            }
            Mock Invoke-AvmBicepTestE2e { throw 'Bicep engine must not run' }
            Mock Invoke-AvmTerraformTestE2e { throw 'Terraform engine must not run' }
            { Invoke-AvmTestE2e -Ecosystem bicep -MaxRetry 1 -SkipModuleVersionCheck } |
                Should -Throw -ExpectedMessage '*MaxRetry*only supported for Terraform*'
            { Invoke-AvmTestE2e -Ecosystem terraform -ResourceGroupPrefix 'avm' `
                    -SkipModuleVersionCheck } |
                Should -Throw -ExpectedMessage '*not supported for Terraform*'
            { Invoke-AvmTestE2e -Ecosystem terraform -WhatIf `
                    -SkipModuleVersionCheck } |
                Should -Throw -ExpectedMessage '*not supported for Terraform*'
            Should -Invoke Invoke-AvmBicepTestE2e -Exactly 0
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 0
        }
    }

    It 'forwards -Ecosystem to Get-AvmModuleContextInternal' {
        $dir = Join-Path $TestDrive ("eco-fwd-e2e-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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
            Mock Invoke-AvmTerraformTestE2e {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 0; Issues = @() }
            }
            Invoke-AvmTestE2e -Path $D -Ecosystem 'terraform' | Out-Null
            $script:eco | Should -Be 'terraform'
        }
    }
}

Describe 'Invoke-AvmTestE2e per-example targeting (F26/F27)' {
    It 'forwards -Example to the engine' {
        $dir = Join-Path $TestDrive ("fwd-ex-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }

            Mock Get-AvmModuleContextInternal { $ctx }
            Mock Invoke-AvmTerraformTestE2e {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 1; Issues = @() }
            }
            Invoke-AvmTestE2e -Path $D -Example 'example-a' | Out-Null

            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 1 -ParameterFilter {
                $Example.Count -eq 1 -and $Example[0] -eq 'example-a'
            }
        }
    }

    It 'forwards -List to the engine' {
        $dir = Join-Path $TestDrive ("fwd-list-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContextInternal { $ctx }
            Mock Test-AvmModuleVersion { throw 'Offline listing must not query PowerShell Gallery' }
            Mock Invoke-AvmTerraformTestE2e { '["example-a"]' }
            $out = Invoke-AvmTestE2e -Path $D -List

            $out | Should -Be '["example-a"]'
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 1 -ParameterFilter { $List.IsPresent }
            Should -Invoke Test-AvmModuleVersion -Exactly 0
        }
    }

    It 'lists Bicep cases through the CLI without a Gallery check or Azure tools' {
        $root = Join-Path $TestDrive ('offline-e2e-' + [guid]::NewGuid().ToString('N'))
        $caseDir = Join-Path $root 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $caseDir -Force
        Set-Content -LiteralPath (Join-Path $root 'main.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $caseDir 'main.test.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Mock Test-AvmModuleVersion { throw 'Offline listing must not check the Gallery' }
            Mock Resolve-AvmTool { throw 'Offline listing must not resolve Bicep' }
            $result = Invoke-Avm 'test' 'e2e' '--ecosystem' 'bicep' `
                '--path' $R '--list'
            $result | Should -Be '["tests/e2e/defaults"]'
            Should -Invoke Test-AvmModuleVersion -Exactly 0
            Should -Invoke Resolve-AvmTool -Exactly 0
        }
    }

    It 'binds the kebab-case CLI flags --example and --list' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 2 -and $_.Path[0] -eq 'test' -and $_.Path[1] -eq 'e2e' }
        $cmd = Get-Command $entry.Cmdlet -Module Avm.Authoring
        $cmd.Parameters.ContainsKey('Example') | Should -BeTrue
        $cmd.Parameters.ContainsKey('List')    | Should -BeTrue
        $cmd.Parameters['Example'].ParameterType.FullName | Should -Be 'System.String[]'
        $cmd.Parameters['List'].SwitchParameter           | Should -BeTrue
    }
}

Describe 'Invoke-AvmTestE2e native workflow options' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            Mock Test-AvmModuleVersion {}
            Mock Get-AvmModuleContextInternal { [pscustomobject]@{ Root = 'test-root'; Ecosystem = $Ecosystem } }
            Mock Invoke-AvmBicepTestE2e { [pscustomobject]@{ Status = 'pass'; Engine = 'bicep' } }
            Mock Invoke-AvmTerraformTestE2e { [pscustomobject]@{ Status = 'pass'; Engine = 'terraform' } }
        }
    }

    It 'checks the module version once with the explicit policy: <SkipCheck>' -ForEach @(
        @{ SkipCheck = $true }
        @{ SkipCheck = $false }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ SkipCheck = $SkipCheck } {
            param($SkipCheck)
            $null = Invoke-AvmTestE2e -Ecosystem bicep -SkipModuleVersionCheck:$SkipCheck
            Should -Invoke Test-AvmModuleVersion -Exactly 1
            Should -Invoke Test-AvmModuleVersion -Exactly 1 -ParameterFilter {
                [bool]$SkipModuleVersionCheck -eq $SkipCheck
            }
            Should -Invoke Get-AvmModuleContextInternal -Exactly 1
        }
    }

    It 'routes the native input, retry and retention options without changing their values' {
        InModuleScope Avm.Authoring {
            $null = Invoke-AvmTestE2e -Ecosystem bicep -ResourceLocation 'East US' -UseCiInputs `
                -TestSubscriptionIds '[{"id":"00000000-0000-0000-0000-000000000001","name":"test"}]' `
                -SubscriptionSelectionSeed 42 -SubscriptionJobIndex 7 -Phase Deploy `
                -CleanupStatePath 'cleanup.json' -KeepResources -DeploymentRetryLimit 2 -ValidationRetryLimit 1
            Should -Invoke Invoke-AvmBicepTestE2e -Exactly 1 -ParameterFilter {
                $ResourceLocation -ceq 'East US' -and $UseCiInputs -and $TestSubscriptionIds -match '"name":"test"' -and
                $SubscriptionSelectionSeed -eq 42 -and $SubscriptionJobIndex -eq 7 -and
                $Phase -eq 'Deploy' -and $CleanupStatePath -ceq 'cleanup.json' -and
                $KeepResources -and $DeploymentRetryLimit -eq 2 -and $ValidationRetryLimit -eq 1
            }
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 0
        }
    }

    It 'binds hosted completion and cleanup paths through the CLI dispatcher' {
        InModuleScope Avm.Authoring {
            $null = Invoke-Avm 'test' 'e2e' '--ecosystem' 'bicep' '--phase' 'Complete' `
                '--cleanup-state-path' 'path with spaces.json' `
                '--subscription-id' '00000000-0000-0000-0000-000000000001' `
                '--tenant-id' '00000000-0000-0000-0000-000000000002' '--skip-module-version-check'
            Should -Invoke Invoke-AvmBicepTestE2e -Exactly 1 -ParameterFilter {
                $Phase -ceq 'Complete' -and $CleanupStatePath -ceq 'path with spaces.json' -and
                $SubscriptionId -eq '00000000-0000-0000-0000-000000000001' -and
                $TenantId -eq '00000000-0000-0000-0000-000000000002'
            }
        }
    }

    It 'rejects the Bicep-only <Option> argument for Terraform' -ForEach @(
        @{ Option = 'ResourceLocation'; Value = 'eastus' }
        @{ Option = 'UseCiInputs'; Value = $true }
        @{ Option = 'TestSubscriptionIds'; Value = '[]' }
        @{ Option = 'SubscriptionSelectionSeed'; Value = 0 }
        @{ Option = 'SubscriptionJobIndex'; Value = 0 }
        @{ Option = 'Phase'; Value = 'All' }
        @{ Option = 'CleanupStatePath'; Value = 'cleanup.json' }
        @{ Option = 'KeepResources'; Value = $false }
        @{ Option = 'DeploymentRetryLimit'; Value = 3 }
        @{ Option = 'ValidationRetryLimit'; Value = 3 }
        @{ Option = 'Recurse'; Value = $true }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Option = $Option; Value = $Value } {
            param($Option, $Value)
            $options = @{ Ecosystem = 'terraform'; $Option = $Value }
            { Invoke-AvmTestE2e @options } | Should -Throw -ExpectedMessage '*not supported for Terraform*'
            Should -Invoke Invoke-AvmBicepTestE2e -Exactly 0
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 0
        }
    }

    It 'preserves explicit false Recurse compatibility on Terraform' {
        InModuleScope Avm.Authoring {
            (Invoke-AvmTestE2e -Ecosystem terraform -Recurse:$false -MaxRetry 0).Engine | Should -Be 'terraform'
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 1 -ParameterFilter { $MaxRetry -eq 0 }
        }
    }

    It 'rejects out-of-range <Option> before entering either engine' -ForEach @(
        @{ Option = 'DeploymentRetryLimit'; Value = 0 }
        @{ Option = 'DeploymentRetryLimit'; Value = 4 }
        @{ Option = 'ValidationRetryLimit'; Value = 0 }
        @{ Option = 'ValidationRetryLimit'; Value = 4 }
        @{ Option = 'SubscriptionSelectionSeed'; Value = -1 }
        @{ Option = 'SubscriptionJobIndex'; Value = -1 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Option = $Option; Value = $Value } {
            param($Option, $Value)
            $options = @{ Ecosystem = 'bicep'; $Option = $Value }
            { Invoke-AvmTestE2e @options } | Should -Throw
            Should -Invoke Invoke-AvmBicepTestE2e -Exactly 0
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 0
        }
    }
}
