#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmCheckPolicy' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmCheckPolicy -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm check policy"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object {
            $_.Path.Count -eq 2 -and $_.Path[0] -eq 'check' -and $_.Path[1] -eq 'policy'
        }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmCheckPolicy'
    }

    It 'dispatches a bicep context to Invoke-AvmBicepCheckPolicy' {
        $dir = Join-Path $TestDrive ("bicep-checkp-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmBicepCheckPolicy {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; Issues = @() }
            }
            Mock Invoke-AvmTerraformCheckPolicy { throw 'wrong engine' }
            $result = Invoke-AvmCheckPolicy -Path $D
            $result.Engine | Should -Be 'bicep'
            Should -Invoke Invoke-AvmBicepCheckPolicy -Exactly 1
            Should -Invoke Invoke-AvmTerraformCheckPolicy -Times 0
        }
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformCheckPolicy' {
        $dir = Join-Path $TestDrive ("tf-checkp-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmTerraformCheckPolicy {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; Issues = @() }
            }
            Mock Invoke-AvmBicepCheckPolicy { throw 'wrong engine' }
            $result = Invoke-AvmCheckPolicy -Path $D
            $result.Engine | Should -Be 'terraform'
            Should -Invoke Invoke-AvmTerraformCheckPolicy -Exactly 1
            Should -Invoke Invoke-AvmBicepCheckPolicy -Times 0
        }
    }

    It 'each engine stub throws AvmConfigurationException for its own ecosystem' {
        $err = InModuleScope 'Avm.Authoring' {
            try {
                Invoke-AvmBicepCheckPolicy -Context ([pscustomobject]@{ Ecosystem = 'bicep'; Root = $TestDrive })
                $null
            }
            catch { $_.Exception }
        }
        $err.GetType().Name        | Should -Be 'AvmConfigurationException'
        $err.Message               | Should -Match 'Bicep policy check is not yet wired'

        $err = InModuleScope 'Avm.Authoring' {
            try {
                Invoke-AvmTerraformCheckPolicy -Context ([pscustomobject]@{ Ecosystem = 'terraform'; Root = $TestDrive })
                $null
            }
            catch { $_.Exception }
        }
        $err.GetType().Name        | Should -Be 'AvmConfigurationException'
        $err.Message               | Should -Match 'Terraform policy check is not yet wired'
    }
}
