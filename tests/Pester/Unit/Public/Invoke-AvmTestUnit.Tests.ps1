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

    It 'rejects a bicep context with AvmConfigurationException' {
        $dir = Join-Path $TestDrive ("bicep-unit-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
                param($D)
                $ctx = [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
                Mock Get-AvmModuleContext { $ctx }
                Mock Invoke-AvmTerraformTestSuite { throw 'should not be called' }
                Invoke-AvmTestUnit -Path $D
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTerraformTestSuite -Times 0
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
