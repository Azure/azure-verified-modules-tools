#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTransform' {
    It 'is wired into the verb registry as "avm transform"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 1 -and $_.Path[0] -eq 'transform' }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmTransform'
    }

    It 'dispatches a bicep context to Invoke-AvmBicepTransform' {
        $dir = Join-Path $TestDrive ("bicep-transform-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmBicepTransform {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' }
            }
            Mock Invoke-AvmTerraformTransform { throw 'wrong engine' }
            $result = Invoke-AvmTransform -Path $D
            $result.Engine | Should -Be 'bicep'
            Should -Invoke Invoke-AvmBicepTransform -Exactly 1
            Should -Invoke Invoke-AvmTerraformTransform -Times 0 -Exactly
        }
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformTransform' {
        $dir = Join-Path $TestDrive ("tf-transform-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmTerraformTransform {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' }
            }
            Mock Invoke-AvmBicepTransform { throw 'wrong engine' }
            $result = Invoke-AvmTransform -Path $D -ThrottleLimit 6
            $result.Engine | Should -Be 'terraform'
            Should -Invoke Invoke-AvmTerraformTransform -Exactly 1 -ParameterFilter {
                $ThrottleLimit -eq 6
            }
            Should -Invoke Invoke-AvmBicepTransform -Times 0 -Exactly
        }
    }

    It 'the Bicep engine accepts a source-free proposed module without generating JSON' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'metadata.json') -Value '{}' -Encoding utf8
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'pinned'; Source = 'cache'; Path = 'bicep' }
            }
            Mock Invoke-AvmProcess { throw 'A proposed module must not be compiled.' }
            Invoke-AvmBicepTransform -Context ([pscustomobject]@{
                    Kind = 'bicep-module'; Ecosystem = 'bicep'; Root = $D
                })
        }
        $result.Status | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 0
        Test-Path -LiteralPath (Join-Path $dir 'main.json') | Should -BeFalse
    }

    It 'each engine rejects a mismatched ecosystem' {
        $err = InModuleScope 'Avm.Authoring' {
            try {
                Invoke-AvmBicepTransform -Context ([pscustomobject]@{ Ecosystem = 'terraform'; Root = $TestDrive })
                $null
            }
            catch { $_.Exception }
        }
        $err.GetType().FullName    | Should -Be 'System.ArgumentException'
        $err.Message               | Should -Match "requires a bicep context"
    }
}
