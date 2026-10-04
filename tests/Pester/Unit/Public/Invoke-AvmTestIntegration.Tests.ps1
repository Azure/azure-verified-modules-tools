#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTestIntegration' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmTestIntegration -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm test integration"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 2 -and $_.Path[0] -eq 'test' -and $_.Path[1] -eq 'integration' }
        $entry        | Should -Not -BeNullOrEmpty
        $entry.Cmdlet | Should -Be 'Invoke-AvmTestIntegration'
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformTestSuite with -Tier integration' {
        $dir = Join-Path $TestDrive ("tf-int-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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
            Invoke-AvmTestIntegration -Path $D
        }
        $result.Engine | Should -Be 'terraform'
        $result.Tier   | Should -Be 'integration'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTerraformTestSuite -Exactly 1 -ParameterFilter { $Tier -eq 'integration' -and $MaxRetry -eq 2 }
        }
    }

    It 'forwards the retry budget and existing CLI options (<Token>)' -ForEach @(
        @{ Token = '--max-retry'; Budget = 0 }
        @{ Token = '-MaxRetry'; Budget = 1 }
        @{ Token = '--max-retry'; Budget = 10 }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Flag = $Token; Budget = $Budget } {
            param($Flag, $Budget)
            Mock Test-AvmDisableSentinel { $null }
            Mock Get-AvmModuleContextInternal { [pscustomobject]@{ Root = 'mock-root'; Ecosystem = 'terraform' } }
            Mock Invoke-AvmTerraformTestSuite {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 1; Issues = @() }
            }
            $null = avm test integration $Flag $Budget --no-init --allow-path-fallback --ecosystem terraform
            Should -Invoke Invoke-AvmTerraformTestSuite -Exactly 1 -ParameterFilter {
                $Tier -eq 'integration' -and $MaxRetry -eq $Budget -and $NoInit -and $AllowPathFallback
            }
        }
    }

    It 'rejects retry counts outside the E2E bounds (<Budget>)' -ForEach @(
        @{ Budget = -1 }; @{ Budget = 11 }
    ) {
        { Invoke-AvmTestIntegration -MaxRetry $Budget } | Should -Throw
    }

    It 'keeps the CLI failure terminating after retry exhaustion' {
        InModuleScope 'Avm.Authoring' {
            Mock Test-AvmDisableSentinel { $null }
            Mock Get-AvmModuleContextInternal { [pscustomobject]@{ Root = 'mock-root'; Ecosystem = 'terraform' } }
            Mock Invoke-AvmTerraformTestSuite {
                [pscustomobject]@{
                    Engine = 'terraform'; Status = 'fail'; FilesProcessed = 1
                    Issues = @([pscustomobject]@{ File = 'main.tf'; Line = 12; Column = 3; Severity = 'error'; Code = ''; Message = 'SkuNotAvailable' })
                }
            }
            { avm test integration --max-retry 2 } | Should -Throw -ExceptionType ([AvmCommandException]) -ExpectedMessage '*SkuNotAvailable*'
        }
    }

    It 'routes a bicep context and forwards ARM scope, tokens and selection' {
        $dir = Join-Path $TestDrive ("bicep-int-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep' }
            }
            Mock Invoke-AvmBicepTestIntegration {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; FilesProcessed = 1; Issues = @() }
            }
            Mock Invoke-AvmTerraformTestSuite { throw 'Terraform must not run' }
            $result = Invoke-AvmTestIntegration -Path $D `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -ResourceGroupName 'existing-test' -TokenFile 'local-tokens.json' `
                -Operation WhatIf -Example defaults -Recurse
            $result.Engine | Should -Be 'bicep'
            Should -Invoke Invoke-AvmBicepTestIntegration -Exactly 1 -ParameterFilter {
                $Operation -eq 'WhatIf' -and $Recurse -and
                $Example.Count -eq 1 -and $Example[0] -eq 'defaults' -and
                $ResourceGroupName -eq 'existing-test' -and
                $TokenFile -eq 'local-tokens.json'
            }
            Should -Invoke Invoke-AvmTerraformTestSuite -Exactly 0
        }
    }

    It 'rejects Bicep-only switches in Terraform and Terraform-only switches in Bicep' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Root = 'mock-root'; Ecosystem = 'terraform' }
            }
            Mock Invoke-AvmTerraformTestSuite { throw 'Must not run on invalid options' }
            { Invoke-AvmTestIntegration -SubscriptionId '00000000-0000-0000-0000-000000000001' } |
                Should -Throw -ExpectedMessage '*only supported for Bicep*'
            { Invoke-AvmTestIntegration -Operation Validate } |
                Should -Throw -ExpectedMessage '*only supported for Bicep*'
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Root = 'mock-root'; Ecosystem = 'bicep' }
            }
            { Invoke-AvmTestIntegration -NoInit } |
                Should -Throw -ExpectedMessage '*only supported for Terraform*'
            { Invoke-AvmTestIntegration -MaxRetry 0 } |
                Should -Throw -ExpectedMessage '*only supported for Terraform*'
        }
    }

    It 'forwards -Ecosystem to Get-AvmModuleContextInternal' {
        $dir = Join-Path $TestDrive ("eco-fwd-int-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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
            Invoke-AvmTestIntegration -Path $D -Ecosystem 'terraform' | Out-Null
            $script:eco | Should -Be 'terraform'
        }
    }
}
