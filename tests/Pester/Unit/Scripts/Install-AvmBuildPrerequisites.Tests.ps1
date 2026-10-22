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
        Mock Get-InstalledPSResource
        Mock Install-PSResource
        Mock Start-Sleep
        Mock Write-Verbose
        Mock Write-Warning
    }

    AfterEach {
        Remove-Variable -Name AvmPrereqInstallAttempts -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name AvmPrereqInstallCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name AvmPrereqLastException -Scope Global -ErrorAction SilentlyContinue
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

        Should -Invoke Install-PSResource -Times 5 -Exactly
        Should -Invoke Install-PSResource -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Pester' -and $Version -eq '5.7.1'
        }
        Should -Invoke Install-PSResource -Times 0 -Exactly -ParameterFilter {
            $Name -eq 'Pester' -and $Version -eq '[5.5.0,)'
        }
        Should -Invoke Install-PSResource -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'powershell-yaml' -and $Version -eq '0.4.12'
        }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter {
            $Milliseconds -ge 500 -and $Milliseconds -le 1000
        }
        Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter {
            $Message -match 'attempt 1 of 3'
        }
    }

    It 'retries an exact Gallery <FailureStage> 404 with the same pin' -TestCases @(
        @{
            FailureStage = 'lookup'
            RequestUri = 'https://www.powershellgallery.com/api/v2/FindPackagesById()?%24filter=Id+eq+%27Pester%27+and+NormalizedVersion+eq+%275.7.1%27'
        }
        @{
            FailureStage = 'download'
            RequestUri = 'https://www.powershellgallery.com/api/v2/package/Pester/5.7.1'
        }
    ) {
        param($FailureStage, $RequestUri)
        $global:AvmPrereqInstallAttempts = 0
        Mock Install-PSResource {
            if ($Name -eq 'Pester') {
                $global:AvmPrereqInstallAttempts++
                if ($global:AvmPrereqInstallAttempts -eq 1) {
                    throw [System.Net.Http.HttpRequestException]::new(
                        "Response status code does not indicate success: 404 (Not Found). Request sent: '$RequestUri'",
                        $null,
                        [System.Net.HttpStatusCode]::NotFound)
                }
            }
        }

        & $script:scriptPath -MaxAttempts 3 -InitialDelaySeconds 0 -Confirm:$false

        Should -Invoke Install-PSResource -Times 2 -Exactly -ParameterFilter {
            $Name -eq 'Pester' -and $Version -eq '5.7.1'
        }
    }

    It 'retries a rendered PSResourceGet 404 in ErrorDetails with the same pin' {
        $global:AvmPrereqInstallAttempts = 0
        $requestUri = 'https://www.powershellgallery.com/api/v2/FindPackagesById()?%24filter=Id+eq+%27Pester%27+and+NormalizedVersion+eq+%275.7.1%27'
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('PSResourceGet failed while resolving the package.'),
            'InstallPSResource',
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $null)
        $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
            "Response status code does not indicate success: 404 (Not Found). Request sent: '$requestUri'")

        Mock Install-PSResource {
            if ($Name -eq 'Pester') {
                $global:AvmPrereqInstallAttempts++
                if ($global:AvmPrereqInstallAttempts -eq 1) {
                    throw $errorRecord
                }
            }
        }

        & $script:scriptPath -MaxAttempts 3 -InitialDelaySeconds 0 -Confirm:$false

        Should -Invoke Install-PSResource -Times 2 -Exactly -ParameterFilter {
            $Name -eq 'Pester' -and $Version -eq '5.7.1'
        }
    }

    It 'surfaces an exhausted exact Gallery 404 after the bounded attempts' {
        $originalException = [System.Net.Http.HttpRequestException]::new(
            "Response status code does not indicate success: 404 (Not Found). Request sent: 'https://www.powershellgallery.com/api/v2/FindPackagesById()?%24filter=Id+eq+%27Pester%27+and+NormalizedVersion+eq+%275.7.1%27'",
            $null,
            [System.Net.HttpStatusCode]::NotFound)
        Mock Install-PSResource {
            if ($Name -eq 'Pester') {
                throw $originalException
            }
        }

        $thrown = $null
        try {
            & $script:scriptPath `
                -MaxAttempts 3 `
                -InitialDelaySeconds 0 `
                -Confirm:$false
        }
        catch {
            $thrown = $_
        }

        [object]::ReferenceEquals($thrown.Exception, $originalException) | Should -BeTrue
        $thrown.ErrorDetails.Message | Should -Match 'Installing Pester could not complete after 3 attempts'
        Should -Invoke Install-PSResource -Times 3 -Exactly -ParameterFilter {
            $Name -eq 'Pester' -and $Version -eq '5.7.1'
        }
    }

    It 'preserves the original ErrorDetails for an exhausted rendered Gallery 404' {
        $requestUri = 'https://www.powershellgallery.com/api/v2/FindPackagesById()?%24filter=Id+eq+%27Pester%27+and+NormalizedVersion+eq+%275.7.1%27'
        $global:AvmPrereqInstallCalls = [System.Collections.Generic.List[string]]::new()
        Mock Install-PSResource {
            if ($Name -eq 'Pester') {
                $global:AvmPrereqInstallCalls.Add("$Name|$Version")
                $originalException = [System.Exception]::new('PSResourceGet failed while resolving the package.')
                $global:AvmPrereqLastException = $originalException
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    $originalException,
                    'InstallPSResource',
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $null)
                $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
                    "Response status code does not indicate success: 404 (Not Found). Request sent: '$requestUri'")
                throw $errorRecord
            }
        }

        $thrown = $null
        try {
            & $script:scriptPath `
                -MaxAttempts 3 `
                -InitialDelaySeconds 0 `
                -Confirm:$false
        }
        catch {
            $thrown = $_
        }

        [object]::ReferenceEquals($thrown.Exception, $global:AvmPrereqLastException) | Should -BeTrue
        $thrown.ErrorDetails.Message | Should -Be "Response status code does not indicate success: 404 (Not Found). Request sent: '$requestUri'"
        $thrown.ErrorDetails.Message | Should -Match ([regex]::Escape($requestUri))
        Should -Invoke Install-PSResource -Times 4 -Exactly
        @($global:AvmPrereqInstallCalls | Where-Object { $_ -eq 'Pester|5.7.1' }).Count | Should -Be 3
    }

    It 'skips an exact pin that is already installed but still resolves version ranges' {
        Mock Get-InstalledPSResource {
            [pscustomobject]@{ Name = 'powershell-yaml'; Version = '0.4.12' }
        } -ParameterFilter { $Name -eq 'powershell-yaml' -and $Version -eq '0.4.12' }

        & $script:scriptPath -Confirm:$false

        Should -Invoke Install-PSResource -Times 2 -Exactly
        Should -Invoke Install-PSResource -Times 0 -Exactly -ParameterFilter { $Name -eq 'powershell-yaml' }
        Should -Invoke Get-InstalledPSResource -Times 2 -Exactly
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

    It 'does not retry an unrelated permanent 404' {
        Mock Install-PSResource {
            throw [System.Net.Http.HttpRequestException]::new(
                'Response status code does not indicate success: 404 (Not Found).',
                $null,
                [System.Net.HttpStatusCode]::NotFound)
        }

        {
            & $script:scriptPath `
                -MaxAttempts 3 `
                -InitialDelaySeconds 0 `
                -Confirm:$false
        } | Should -Throw '*404 (Not Found)*'

        Should -Invoke Install-PSResource -Times 1 -Exactly
    }

    It 'installs exact policy pins only when requested' -TestCases @(
        @{ IncludePolicy = $true; PolicyInstallCount = 2 }
        @{ IncludePolicy = $false; PolicyInstallCount = 0 }
    ) {
        param($IncludePolicy, $PolicyInstallCount)
        & $script:scriptPath -IncludeBicepPolicy:$IncludePolicy -Confirm:$false

        Should -Invoke Install-PSResource -Times $PolicyInstallCount -Exactly -ParameterFilter {
            ($Name -eq 'PSRule' -and $Version -eq '2.9.0') -or
            ($Name -eq 'PSRule.Rules.Azure' -and $Version -eq '1.47.0')
        }
        Should -Invoke Install-PSResource -Times (3 + $PolicyInstallCount) -Exactly
    }

    It 'reuses installed policy pins without Gallery requests' {
        Mock Get-InstalledPSResource {
            [pscustomobject]@{ Name = $Name; Version = $Version }
        } -ParameterFilter {
            ($Name -eq 'PSRule' -and $Version -eq '2.9.0') -or
            ($Name -eq 'PSRule.Rules.Azure' -and $Version -eq '1.47.0')
        }
        & $script:scriptPath -IncludeBicepPolicy -Confirm:$false

        Should -Invoke Install-PSResource -Times 3 -Exactly
        Should -Invoke Install-PSResource -Times 0 -Exactly -ParameterFilter {
            $Name -in @('PSRule', 'PSRule.Rules.Azure')
        }
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