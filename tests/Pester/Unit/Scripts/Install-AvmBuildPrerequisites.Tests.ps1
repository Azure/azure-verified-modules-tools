#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Install-AvmBuildPrerequisites.ps1' {
    BeforeAll {
        $script:scriptPath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'scripts' 'Install-AvmBuildPrerequisites.ps1'
    }

    BeforeEach {
        Mock Get-Module {
            [pscustomobject]@{ Name = 'Microsoft.PowerShell.PSResourceGet' }
        } -ParameterFilter { $ListAvailable }
        Mock Import-Module
        Mock Install-PSResource
        Mock Start-Sleep
        Mock Write-Warning
    }

    AfterEach {
        Remove-Variable -Name AvmPrereqInstallAttempts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'retries a transient Gallery network failure and installs every prerequisite' {
        $global:AvmPrereqInstallAttempts = 0
        Mock Install-PSResource {
            $global:AvmPrereqInstallAttempts++
            if ($global:AvmPrereqInstallAttempts -eq 1) {
                throw [System.Net.Http.HttpRequestException]::new(
                    'No route to host (www.powershellgallery.com:443)')
            }
        }

        & $script:scriptPath `
            -IncludePSScriptAnalyzer `
            -MaxAttempts 3 `
            -InitialDelaySeconds 1 `
            -Confirm:$false

        Should -Invoke Install-PSResource -Times 4 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter {
            $Seconds -eq 1
        }
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -match 'attempt 1 of 3'
        }
    }

    It 'does not retry a deterministic package failure' {
        Mock Install-PSResource {
            throw [System.InvalidOperationException]::new('Package version is invalid.')
        }

        {
            & $script:scriptPath `
                -MaxAttempts 3 `
                -InitialDelaySeconds 0 `
                -Confirm:$false
        } | Should -Throw '*Package version is invalid*'

        Should -Invoke Install-PSResource -Times 1 -Exactly
    }

    It 'throws after the configured number of transient attempts' {
        Mock Install-PSResource {
            throw [System.Net.Http.HttpRequestException]::new(
                'The service is temporarily unavailable.')
        }

        {
            & $script:scriptPath `
                -MaxAttempts 3 `
                -InitialDelaySeconds 0 `
                -Confirm:$false
        } | Should -Throw '*temporarily unavailable*'

        Should -Invoke Install-PSResource -Times 3 -Exactly
    }
}
