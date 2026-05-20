#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmCheckConvention' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmCheckConvention -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm check convention"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object {
            $_.Path.Count -eq 2 -and $_.Path[0] -eq 'check' -and $_.Path[1] -eq 'convention'
        }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmCheckConvention'
    }

    It 'dispatches a bicep context to Invoke-AvmBicepCheckConvention' {
        $dir = Join-Path $TestDrive ("bicep-checkc-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmBicepCheckConvention {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; Issues = @() }
            }
            Mock Invoke-AvmTerraformCheckConvention { throw 'wrong engine' }
            $result = Invoke-AvmCheckConvention -Path $D
            $result.Engine | Should -Be 'bicep'
            Should -Invoke Invoke-AvmBicepCheckConvention -Exactly 1
            Should -Invoke Invoke-AvmTerraformCheckConvention -Times 0
        }
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformCheckConvention' {
        $dir = Join-Path $TestDrive ("tf-checkc-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmTerraformCheckConvention {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; Issues = @() }
            }
            Mock Invoke-AvmBicepCheckConvention { throw 'wrong engine' }
            $result = Invoke-AvmCheckConvention -Path $D
            $result.Engine | Should -Be 'terraform'
            Should -Invoke Invoke-AvmTerraformCheckConvention -Exactly 1
            Should -Invoke Invoke-AvmBicepCheckConvention -Times 0
        }
    }

    It 'each engine stub throws AvmConfigurationException for its own ecosystem' {
        $err = InModuleScope 'Avm.Authoring' {
            try {
                Invoke-AvmBicepCheckConvention -Context ([pscustomobject]@{ Ecosystem = 'bicep'; Root = $TestDrive })
                $null
            }
            catch { $_.Exception }
        }
        $err.GetType().Name        | Should -Be 'AvmConfigurationException'
        $err.Message               | Should -Match 'Bicep convention check is not yet wired'

        $err = InModuleScope 'Avm.Authoring' {
            try {
                Invoke-AvmTerraformCheckConvention -Context ([pscustomobject]@{ Ecosystem = 'terraform'; Root = $TestDrive })
                $null
            }
            catch { $_.Exception }
        }
        $err.GetType().Name        | Should -Be 'AvmConfigurationException'
        $err.Message               | Should -Match 'Terraform convention check is not yet wired'
    }
}
