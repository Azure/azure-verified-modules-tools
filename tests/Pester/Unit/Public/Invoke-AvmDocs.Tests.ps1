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
            Mock Get-AvmModuleContextInternal { $ctx }
            Mock Invoke-AvmTerraformDocs {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 1; Changed = @() }
            }
            Mock Invoke-AvmBicepDocs { throw 'wrong engine' }
            Invoke-AvmDocs -Path $D
        }
        $result.Engine | Should -Be 'terraform'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTerraformDocs -Exactly 1
            Should -Invoke Invoke-AvmBicepDocs -Times 0 -Exactly
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
            Mock Get-AvmModuleContextInternal { $ctx }
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
            Mock Get-AvmModuleContextInternal {
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
    It 'threads -CheckDrift to the terraform engine' {
        $dir = Join-Path $TestDrive ("docs-drift-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmTerraformDocs {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'fail'; FilesProcessed = 1; Changed = @('README.md'); Issues = @() }
            }
            Invoke-AvmDocs -Path $D -CheckDrift | Out-Null
            Should -Invoke Invoke-AvmTerraformDocs -Exactly 1 -ParameterFilter { $CheckDrift -eq $true }
        }
    }

    It 'forwards -CheckDrift to the Bicep engine without writing' {
        $dir = Join-Path $TestDrive ("docs-drift-bicep-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmBicepDocs {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'fail'; FilesProcessed = 1; Changed = @(); Issues = @() }
            }
            (Invoke-AvmDocs -Path $D -CheckDrift).Status | Should -Be 'fail'
            Should -Invoke Invoke-AvmBicepDocs -Exactly 1 -ParameterFilter { $CheckDrift }
        }
    }

    It 'forwards -WhatIf to Bicep and refuses Terraform until its engine supports it' {
        $dir = Join-Path $TestDrive 'docs-whatif'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep' }
            }
            Mock Invoke-AvmBicepDocs {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'skipped'; FilesProcessed = 1; Changed = @() }
            }
            (Invoke-AvmDocs -Path $D -WhatIf).Status | Should -Be 'skipped'
            Should -Invoke Invoke-AvmBicepDocs -Exactly 1 -ParameterFilter { $WhatIf }
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform' }
            }
            Mock Invoke-AvmTerraformDocs { throw 'would rewrite Terraform files' }
            { Invoke-AvmDocs -Path $D -WhatIf } | Should -Throw '*does not support -WhatIf*'
            Should -Invoke Invoke-AvmTerraformDocs -Exactly 0
        }
    }
}