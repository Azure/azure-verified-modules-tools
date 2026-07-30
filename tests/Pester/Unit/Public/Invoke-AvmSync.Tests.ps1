#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmSync' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmSync -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm sync"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 1 -and $_.Path[0] -eq 'sync' }
        $entry        | Should -Not -BeNullOrEmpty
        $entry.Cmdlet | Should -Be 'Invoke-AvmSync'
    }

    It 'dispatches a terraform context to Sync-AvmManagedFile' {
        $dir = Join-Path $TestDrive ("tf-sync-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Sync-AvmManagedFile {
                [pscustomobject]@{ Engine = 'terraform'; Tool = 'managed-files'; Status = 'pass'; FilesProcessed = 1; Issues = @() }
            }
            Invoke-AvmSync -Path $D
        }
        $result.Engine | Should -Be 'terraform'
        $result.Status | Should -Be 'pass'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Sync-AvmManagedFile -Exactly 1
        }
    }

    It 'forwards -AllowPathFallback to the engine' {
        $dir = Join-Path $TestDrive ("apf-sync-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Sync-AvmManagedFile {
                [pscustomobject]@{ Engine = 'terraform'; Tool = 'managed-files'; Status = 'pass'; FilesProcessed = 0; Issues = @() }
            }
            Invoke-AvmSync -Path $D -AllowPathFallback | Out-Null

            Should -Invoke Sync-AvmManagedFile -Exactly 1 -ParameterFilter { $AllowPathFallback.IsPresent }
        }
    }

    It 'forwards -CheckDrift to the engine' {
        $dir = Join-Path $TestDrive ("drift-sync-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Sync-AvmManagedFile {
                [pscustomobject]@{ Engine = 'terraform'; Tool = 'managed-files'; Status = 'pass'; FilesProcessed = 0; Issues = @() }
            }
            Invoke-AvmSync -Path $D -CheckDrift | Out-Null

            Should -Invoke Sync-AvmManagedFile -Exactly 1 -ParameterFilter { $CheckDrift.IsPresent }
        }
    }

    It 'rejects a bicep context with AvmConfigurationException' {
        $dir = Join-Path $TestDrive ("bicep-sync-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
                param($D)
                $ctx = [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
                Mock Get-AvmModuleContext { $ctx }
                Mock Sync-AvmManagedFile { throw 'should not be called' }
                Invoke-AvmSync -Path $D
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Sync-AvmManagedFile -Times 0
        }
    }

    It 'forwards -Ecosystem to Get-AvmModuleContext' {
        $dir = Join-Path $TestDrive ("eco-fwd-sync-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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
            Mock Sync-AvmManagedFile {
                [pscustomobject]@{ Engine = 'terraform'; Tool = 'managed-files'; Status = 'pass'; FilesProcessed = 0; Issues = @() }
            }
            Invoke-AvmSync -Path $D -Ecosystem 'terraform' | Out-Null
            $script:eco | Should -Be 'terraform'
        }
    }
}
