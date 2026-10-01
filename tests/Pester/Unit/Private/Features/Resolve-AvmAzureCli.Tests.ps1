#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-AvmAzureCli' {
    It 'requires an installed Azure CLI without silently falling back to another command' {
        InModuleScope Avm.Authoring {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
            { Resolve-AvmAzureCli } | Should -Throw '*Azure CLI is required*'
        }
    }

    It 'uses the resolved absolute native executable' {
        $executable = Join-Path ([System.IO.Path]::GetTempPath()) 'az.exe'
        InModuleScope Avm.Authoring -Parameters @{ Executable = $executable } {
            param($Executable)
            Mock Get-Command { [pscustomobject]@{ Source = $Executable } } `
                -ParameterFilter { $Name -eq 'az' }
            $cli = Resolve-AvmAzureCli
            $cli.Path | Should -BeExactly $Executable
            @($cli.ArgumentPrefix).Count | Should -Be 0
            $cli.EnvVars.Count | Should -Be 0
        }
    }

    It 'runs the Windows MSI Python entrypoint without executing az.cmd or a shell' -Skip:(-not $IsWindows) {
        $wrapper = Join-Path ([System.IO.Path]::GetTempPath()) 'avm-az' 'wbin' 'az.cmd'
        $python = Join-Path (Split-Path -Parent (Split-Path -Parent $wrapper)) 'python.exe'
        InModuleScope Avm.Authoring -Parameters @{ Wrapper = $wrapper; Python = $python } {
            param($Wrapper, $Python)
            Mock Get-Command { [pscustomobject]@{ Source = $Wrapper } } `
                -ParameterFilter { $Name -eq 'az' }
            Mock Test-Path { $true }
            $cli = Resolve-AvmAzureCli
            $cli.Path | Should -BeExactly $Python
            $cli.ArgumentPrefix -join ' ' | Should -BeExactly '-IBm azure.cli'
            $cli.EnvVars.AZ_INSTALLER | Should -BeExactly 'MSI'
        }
    }

    It 'fails if the Windows MSI entrypoint cannot be found' -Skip:(-not $IsWindows) {
        $wrapper = Join-Path ([System.IO.Path]::GetTempPath()) 'avm-az' 'wbin' 'az.cmd'
        InModuleScope Avm.Authoring -Parameters @{ Wrapper = $wrapper } {
            param($Wrapper)
            Mock Get-Command { [pscustomobject]@{ Source = $Wrapper } } `
                -ParameterFilter { $Name -eq 'az' }
            Mock Test-Path { $false }
            { Resolve-AvmAzureCli } | Should -Throw '*Repair the Azure CLI installation*'
        }
    }
}
