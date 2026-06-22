#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTest' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmTest -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm test"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 1 -and $_.Path[0] -eq 'test' }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmTest'
    }

    It 'dispatches a bicep context to Invoke-AvmBicepTest' {
        $dir = Join-Path $TestDrive ("bicep-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Invoke-AvmBicepTest {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; FilesProcessed = 4; Issues = @() }
            }
            Mock Invoke-AvmTerraformTest { throw 'wrong engine' }
            Invoke-AvmTest -Path $D
        }
        $result.Engine | Should -Be 'bicep'
        $result.Status | Should -Be 'pass'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmBicepTest -Exactly 1
            Should -Invoke Invoke-AvmTerraformTest -Times 0
        }
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformTest' {
        $dir = Join-Path $TestDrive ("tf-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Invoke-AvmTerraformTest {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; Issues = @() }
            }
            Mock Invoke-AvmBicepTest { throw 'wrong engine' }
            Invoke-AvmTest -Path $D
        }
        $result.Engine | Should -Be 'terraform'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTerraformTest -Exactly 1
        }
    }

    It 'forwards -Ecosystem to Get-AvmModuleContext' {
        $dir = Join-Path $TestDrive ("eco-fwd-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $script:eco = $null
            Mock Get-AvmModuleContext {
                param($Path, $Ecosystem)
                $script:eco = $Ecosystem
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmBicepTest {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; FilesProcessed = 0; Issues = @() }
            }
            Invoke-AvmTest -Path $D -Ecosystem 'bicep' | Out-Null
            $script:eco | Should -Be 'bicep'
        }
    }
}
