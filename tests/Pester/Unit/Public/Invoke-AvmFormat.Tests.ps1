#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmFormat' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmFormat -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm format"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 1 -and $_.Path[0] -eq 'format' }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmFormat'
    }

    It 'supports ShouldProcess (no-ops under -WhatIf)' {
        $dir = Join-Path $TestDrive ("bicep-mod-wif-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'main.bicep') -Value 'param x string' -Encoding utf8

        $sentinel = $null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx } -ParameterFilter { $true }
            Mock Format-AvmBicepModule { 'should-not-run' }
            $script:result = Invoke-AvmFormat -Path $D -WhatIf
            Should -Invoke Format-AvmBicepModule -Times 0 -Exactly
        }
    }

    It 'dispatches a bicep context to Format-AvmBicepModule' {
        $dir = Join-Path $TestDrive ("bicep-mod-disp-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Format-AvmBicepModule {
                [pscustomobject]@{ Engine = 'bicep'; FilesProcessed = 7; Changed = @() }
            }
            Mock Format-AvmTerraformModule { throw 'wrong engine' }
            Invoke-AvmFormat -Path $D
        }
        $result.Engine         | Should -Be 'bicep'
        $result.FilesProcessed | Should -Be 7

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Format-AvmBicepModule -Exactly 1
            Should -Invoke Format-AvmTerraformModule -Times 0 -Exactly
        }
    }

    It 'dispatches a terraform context to Format-AvmTerraformModule' {
        $dir = Join-Path $TestDrive ("tf-mod-disp-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Format-AvmTerraformModule {
                [pscustomobject]@{ Engine = 'terraform'; Changed = @('main.tf') }
            }
            Mock Format-AvmBicepModule { throw 'wrong engine' }
            Invoke-AvmFormat -Path $D
        }
        $result.Engine | Should -Be 'terraform'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Format-AvmTerraformModule -Exactly 1
        }
    }

    It 'forwards -Ecosystem to Get-AvmModuleContext' {
        $dir = Join-Path $TestDrive ("eco-fwd-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $passed = $null
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
            Mock Format-AvmBicepModule {
                [pscustomobject]@{ Engine = 'bicep'; FilesProcessed = 0; Changed = @() }
            }
            Invoke-AvmFormat -Path $D -Ecosystem 'bicep' | Out-Null
            $script:eco | Should -Be 'bicep'
        }
    }
    It 'threads -CheckDrift to the terraform engine' {
        $dir = Join-Path $TestDrive ("fmt-drift-tf-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Format-AvmTerraformModule {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'fail'; FilesProcessed = 1; Changed = @('main.tf'); Issues = @() }
            }
            Invoke-AvmFormat -Path $D -CheckDrift | Out-Null
            Should -Invoke Format-AvmTerraformModule -Exactly 1 -ParameterFilter { $CheckDrift -eq $true }
        }
    }

    It 'threads -CheckDrift to the bicep engine' {
        $dir = Join-Path $TestDrive ("fmt-drift-bicep-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Format-AvmBicepModule {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; FilesProcessed = 0; Changed = @(); Issues = @() }
            }
            Invoke-AvmFormat -Path $D -CheckDrift | Out-Null
            Should -Invoke Format-AvmBicepModule -Exactly 1 -ParameterFilter { $CheckDrift -eq $true }
        }
    }

    It 'does not request drift mode by default' {
        $dir = Join-Path $TestDrive ("fmt-nodrift-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Format-AvmTerraformModule {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 1; Changed = @(); Issues = @() }
            }
            Invoke-AvmFormat -Path $D | Out-Null
            Should -Invoke Format-AvmTerraformModule -Exactly 0 -ParameterFilter { $CheckDrift -eq $true }
        }
    }
}