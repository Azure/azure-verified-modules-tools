#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmDocs' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmDocs -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm docs"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 1 -and $_.Path[0] -eq 'docs' }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmDocs'
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformDocs' {
        $dir = Join-Path $TestDrive ("tf-docs-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Invoke-AvmTerraformDocs {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 1; Changed = @() }
            }
            Mock Invoke-AvmBicepDocs { throw 'wrong engine' }
            Invoke-AvmDocs -Path $D
        }
        $result.Engine | Should -Be 'terraform'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTerraformDocs -Exactly 1
            Should -Invoke Invoke-AvmBicepDocs -Times 0
        }
    }

    It 'dispatches a bicep context to Invoke-AvmBicepDocs' {
        $dir = Join-Path $TestDrive ("bicep-docs-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Invoke-AvmBicepDocs {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; FilesProcessed = 0; Changed = @() }
            }
            Mock Invoke-AvmTerraformDocs { throw 'wrong engine' }
            Invoke-AvmDocs -Path $D
        }
        $result.Engine | Should -Be 'bicep'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmBicepDocs -Exactly 1
        }
    }

    It 'forwards -OutputFile to the engine' {
        $dir = Join-Path $TestDrive ("docs-of-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            $script:capturedFile = $null
            Mock Invoke-AvmTerraformDocs {
                param($Context, $AllowPathFallback, $OutputFile)
                $script:capturedFile = $OutputFile
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 1; Changed = @() }
            }
            Invoke-AvmDocs -Path $D -OutputFile 'docs/MODULE.md' | Out-Null
            $script:capturedFile | Should -Be 'docs/MODULE.md'
        }
    }
}
