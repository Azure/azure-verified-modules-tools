#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTerraformInit' {
    It 'locks a shared provider cache and forwards init arguments' {
        $probe = InModuleScope 'Avm.Authoring' -Parameters @{
            CachePath = Join-Path $TestDrive 'provider-cache'
        } {
            param($CachePath)

            $script:initLock = [System.IO.MemoryStream]::new()
            Mock Lock-AvmToolCache { $script:initLock }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0 }
            }

            $result = Invoke-AvmTerraformInit `
                -TerraformPath 'terraform' `
                -WorkingDirectory $TestDrive `
                -EnvVars @{ TF_PLUGIN_CACHE_DIR = $CachePath } `
                -Label 'fixture init' `
                -NoColor `
                -StreamOutput

            Should -Invoke Lock-AvmToolCache -Exactly 1 -ParameterFilter {
                $LockFile -eq (Join-Path $CachePath '.avm-terraform.lock') -and
                $TimeoutSec -eq 600
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq 'terraform' -and
                $WorkingDirectory -eq $TestDrive -and
                $Label -eq 'fixture init' -and
                $StreamOutput -and
                ($ArgumentList -join ' ') -eq 'init -upgrade -input=false -no-color'
            }

            [pscustomobject]@{
                ExitCode = $result.ExitCode
                Disposed = -not $script:initLock.CanRead
            }
        }

        $probe.ExitCode | Should -Be 0
        $probe.Disposed | Should -BeTrue
    }

    It 'releases the cache lock when terraform init fails' {
        $disposed = InModuleScope 'Avm.Authoring' -Parameters @{
            CachePath = Join-Path $TestDrive 'provider-cache'
        } {
            param($CachePath)

            $script:initLock = [System.IO.MemoryStream]::new()
            Mock Lock-AvmToolCache { $script:initLock }
            Mock Invoke-AvmProcess {
                throw [System.InvalidOperationException]::new('init failed')
            }

            {
                Invoke-AvmTerraformInit `
                    -TerraformPath 'terraform' `
                    -WorkingDirectory $TestDrive `
                    -EnvVars @{ TF_PLUGIN_CACHE_DIR = $CachePath }
            } | Should -Throw -ExceptionType ([System.InvalidOperationException])

            -not $script:initLock.CanRead
        }

        $disposed | Should -BeTrue
    }

    It 'does not lock when the effective provider cache is disabled' {
        InModuleScope 'Avm.Authoring' {
            Mock Lock-AvmToolCache { throw 'unexpected lock' }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0 }
            }

            $null = Invoke-AvmTerraformInit `
                -TerraformPath 'terraform' `
                -WorkingDirectory $TestDrive `
                -EnvVars @{ TF_PLUGIN_CACHE_DIR = $null }

            Should -Invoke Lock-AvmToolCache -Exactly 0
            Should -Invoke Invoke-AvmProcess -Exactly 1
        }
    }
}
