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
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmTestUnit -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm test unit"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 2 -and $_.Path[0] -eq 'test' -and $_.Path[1] -eq 'unit' }
        $entry        | Should -Not -BeNullOrEmpty
        $entry.Cmdlet | Should -Be 'Invoke-AvmTestUnit'
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformTestSuite with -Tier unit' {
        $dir = Join-Path $TestDrive ("tf-unit-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
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
            Mock Get-AvmModuleContext { $ctx }
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
                $CompliancePath -eq 'module.tests.ps1' -and $RepositoryRoot -eq $D
            }
            Should -Invoke Invoke-AvmTerraformTestSuite -Times 0 -Exactly
        }
    }

    It 'rejects options belonging to the other ecosystem instead of ignoring them' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmModuleContext {
                [pscustomobject]@{ Kind = 'bicep-module'; Root = 'module'; Ecosystem = 'bicep' }
            }
            { Invoke-AvmTestUnit -NoInit } |
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*Terraform*'

            Mock Get-AvmModuleContext {
                [pscustomobject]@{ Kind = 'terraform-module-repo'; Root = 'module'; Ecosystem = 'terraform' }
            }
            { Invoke-AvmTestUnit -Tag 'unit' } |
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*Bicep*'
        }
    }

    It 'forwards -Ecosystem to Get-AvmModuleContext' {
        $dir = Join-Path $TestDrive ("eco-fwd-unit-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $script:eco = $null
            Mock Get-AvmModuleContext {
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
