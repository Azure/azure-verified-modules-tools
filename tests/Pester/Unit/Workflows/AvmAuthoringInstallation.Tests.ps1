#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    $workflowRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows'
    $installCases = @(foreach ($workflowName in @(
            'repository-management-issue-owner-routing.yml',
            'repository-management-module-list-sync.yml',
            'repository-management-pr-reviewer-routing.yml',
            'repository-management-sync.yml',
            'repository-management-workflow-failure-issues.yml'
        )) {
        $workflow = Get-Content -LiteralPath (Join-Path $workflowRoot $workflowName) -Raw
        $step = [regex]::Match(
            $workflow,
            '(?ms)^      - name: [^\r\n]*(?:Install|Load) Avm\.Authoring[^\r\n]*\r?\n(?<body>.*?)(?=^      - |\z)'
        )
        $run = [regex]::Match(
            $step.Groups['body'].Value,
            '(?ms)^        run: (?:&install-avm-authoring )?\|\r?\n(?<script>.*)\z'
        )
        if (-not $run.Success) {
            throw [System.InvalidOperationException]::new("Could not find the installer in $workflowName.")
        }
        @{
            WorkflowName = $workflowName
            InstallScript = $run.Groups['script'].Value -replace '(?m)^ {10}', ''
            HasBootstrap = $workflowName -ne 'repository-management-sync.yml'
            IsBicep = $false
            SupportsWorkflowAuthoringSource = $workflowName -eq 'repository-management-sync.yml'
        }
    })
    foreach ($workflowFile in Get-ChildItem -LiteralPath $workflowRoot -Filter 'bicep*.yml') {
        $workflow = Get-Content -LiteralPath $workflowFile.FullName -Raw
        $installCount = [regex]::Matches($workflow, 'Install-PSResource -Name Avm\.Authoring').Count
        $blocks = @([regex]::Matches(
            $workflow,
            '(?ms)^          if \(\$env:AVM_AUTHORING_MODULE -eq ''Avm\.Authoring''\) \{\r?\n.*?^          Import-Module \$env:AVM_AUTHORING_MODULE -ErrorAction Stop\r?$'
        )) + @([regex]::Matches(
            $workflow,
            '(?ms)^          \$maxAttempts = 3\r?\n.*?^          Import-Module Avm\.Authoring -ErrorAction Stop\r?$'
        ))
        if ($blocks.Count -ne $installCount) {
            throw [System.InvalidOperationException]::new("Could not isolate every installer in $($workflowFile.Name).")
        }
        for ($index = 0; $index -lt $blocks.Count; $index++) {
            $installCases += @{
                WorkflowName = "$($workflowFile.Name) [$($index + 1)]"
                InstallScript = $blocks[$index].Value -replace '(?m)^ {10}', ''
                HasBootstrap = $true
                IsBicep = $true
                SupportsWorkflowAuthoringSource = $false
            }
        }
    }
}

Describe 'Avm.Authoring installation in <WorkflowName>' -ForEach $installCases {
    BeforeAll {
        $installer = [scriptblock]::Create($InstallScript)
        function avm {
            throw [System.InvalidOperationException]::new('avm must be mocked.')
        }
        function Invoke-AvmPreCommit {
            param([string] $RepoId)
            throw [System.InvalidOperationException]::new('Invoke-AvmPreCommit must not run.')
        }
        function Install-Module {
            [CmdletBinding()]
            param(
                [string] $Name,
                [version] $MinimumVersion,
                [string] $Scope,
                [switch] $Force,
                [switch] $AllowClobber
            )
            throw [System.InvalidOperationException]::new('Install-Module must be mocked.')
        }
        function Install-PSResource {
            [CmdletBinding()]
            param(
                [string] $Name,
                [string] $Scope,
                [string] $Version,
                [string] $Repository,
                [switch] $TrustRepository
            )
            throw [System.InvalidOperationException]::new('Install-PSResource must be mocked.')
        }
        function Get-PSResourceRepository {
            [CmdletBinding()]
            param()
            throw [System.InvalidOperationException]::new('Get-PSResourceRepository must be mocked.')
        }
        function Register-PSResourceRepository {
            [CmdletBinding()]
            param([string] $Name, [string] $Uri, [string] $ApiVersion, [switch] $Trusted)
            throw [System.InvalidOperationException]::new('Register-PSResourceRepository must be mocked.')
        }
        function Find-PSResource {
            [CmdletBinding()]
            param([string] $Name, [string] $Repository)
            throw [System.InvalidOperationException]::new('Find-PSResource must be mocked.')
        }
    }

    BeforeEach {
        $previousEnvironment = @{}
        foreach ($name in @('AVM_AUTHORING_VERSION', 'AVM_AUTHORING_MODULE', 'USE_WORKFLOW_AUTHORING_SOURCE', 'GITHUB_WORKSPACE')) {
            $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $env:AVM_AUTHORING_VERSION = $null
        $env:AVM_AUTHORING_MODULE = 'Avm.Authoring'
        $env:USE_WORKFLOW_AUTHORING_SOURCE = 'false'
        $env:GITHUB_WORKSPACE = Join-Path $TestDrive 'repository'
        $global:AvmWorkflowInstallAttempts = 0
        $global:AvmWorkflowBootstrapAttempts = 0

        Mock Get-Module {
            [pscustomobject]@{ Name = 'Microsoft.PowerShell.PSResourceGet'; Version = [version]'1.1.1' }
        } -ParameterFilter { $ListAvailable -and $Name -eq 'Microsoft.PowerShell.PSResourceGet' }
        Mock Import-Module
        Mock Install-Module
        Mock Install-PSResource
        Mock Get-PSResourceRepository { [pscustomobject]@{ Name = 'UserFeed'; Priority = 10; Uri = 'https://example.invalid/gallery' } }
        Mock Register-PSResourceRepository {}
        Mock Find-PSResource { [pscustomobject]@{ Version = [version]'2.0.0' } }
        Mock Start-Sleep
        Mock Write-Warning
        Mock avm
    }

    AfterEach {
        foreach ($name in $previousEnvironment.Keys) {
            $value = $previousEnvironment[$name]
            if ($null -eq $value) { $value = [NullString]::Value }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
        Remove-Variable -Name AvmWorkflowInstallAttempts, AvmWorkflowBootstrapAttempts -Scope Global
    }

    It 'installs the latest version once without sleeping when successful' {
        & $installer

        Should -Invoke Install-PSResource -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Avm.Authoring' -and $Scope -eq 'CurrentUser' -and
            $TrustRepository -and $ErrorAction -eq 'Stop' -and $Version -eq '2.0.0' -and $Repository -eq 'UserFeed'
        }
        Should -Invoke Register-PSResourceRepository -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'MAR' -and $Uri -eq 'https://mcr.microsoft.com/' -and
            $ApiVersion -eq 'ContainerRegistry' -and $Trusted
        }
        Should -Invoke Install-Module -Times 0 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Write-Warning -Times 0 -Exactly
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Avm.Authoring' }
    }

    It 'recovers from the reported Gallery HTTP 504 and logs the retry' {
        Mock Install-PSResource {
            $global:AvmWorkflowInstallAttempts++
            if ($global:AvmWorkflowInstallAttempts -eq 1) {
                throw [System.Net.Http.HttpRequestException]::new(
                    'Response status code does not indicate success: 504 (Gateway Time-out).')
            }
        }

        & $installer

        Should -Invoke Install-PSResource -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -like '*attempt 1 of 3*504*Retrying in 5 seconds*'
        }
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Avm.Authoring' }
    }

    It 'retries non-terminating installation errors instead of continuing without the module' {
        Mock Install-PSResource {
            $global:AvmWorkflowInstallAttempts++
            if ($global:AvmWorkflowInstallAttempts -eq 1) {
                Write-Error 'The Gallery download failed.'
            }
        }

        & $installer

        Should -Invoke Install-PSResource -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Avm.Authoring' }
    }

    It 'allows the final attempt to succeed with increasing delays' {
        Mock Install-PSResource {
            $global:AvmWorkflowInstallAttempts++
            if ($global:AvmWorkflowInstallAttempts -lt 3) {
                throw [System.Net.Http.HttpRequestException]::new('Gallery connection reset.')
            }
        }

        & $installer

        Should -Invoke Install-PSResource -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 10 }
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Avm.Authoring' }
    }

    It 'rethrows the last error after three failures without importing or running Avm.Authoring' {
        Mock Install-PSResource {
            throw [System.Net.Http.HttpRequestException]::new('Gallery HTTP 504.')
        }

        { & $installer } | Should -Throw '*Gallery HTTP 504*'

        Should -Invoke Install-PSResource -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 10 }
        Should -Invoke Write-Warning -Times 2 -Exactly
        Should -Invoke Import-Module -Times 0 -Exactly -ParameterFilter { $Name -eq 'Avm.Authoring' }
        Should -Invoke avm -Times 0 -Exactly
    }

    It 'does not repeat a successful installation when importing Avm.Authoring fails' {
        Mock Import-Module {
            throw [System.InvalidOperationException]::new('Avm.Authoring import failed.')
        } -ParameterFilter { $Name -eq 'Avm.Authoring' }

        { & $installer } | Should -Throw '*Avm.Authoring import failed*'

        Should -Invoke Install-PSResource -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke avm -Times 0 -Exactly
    }

    if ($HasBootstrap) {
        It 'retries a failed PSResourceGet bootstrap before installing Avm.Authoring' {
            Mock Get-Module { } -ParameterFilter {
                $ListAvailable -and $Name -eq 'Microsoft.PowerShell.PSResourceGet'
            }
            Mock Install-Module {
                $global:AvmWorkflowBootstrapAttempts++
                if ($global:AvmWorkflowBootstrapAttempts -eq 1) {
                    throw [System.Net.Http.HttpRequestException]::new('PSResourceGet download failed.')
                }
            }

            & $installer

            Should -Invoke Install-Module -Times 2 -Exactly -ParameterFilter {
                $Name -eq 'Microsoft.PowerShell.PSResourceGet' -and $Scope -eq 'CurrentUser' -and
                $Force -and $AllowClobber -and $ErrorAction -eq 'Stop'
            }
            Should -Invoke Install-PSResource -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        }

        It 'stops after three bootstrap failures without attempting to install Avm.Authoring' {
            Mock Get-Module { } -ParameterFilter {
                $ListAvailable -and $Name -eq 'Microsoft.PowerShell.PSResourceGet'
            }
            Mock Install-Module {
                throw [System.Net.Http.HttpRequestException]::new('PSResourceGet download failed.')
            }

            { & $installer } | Should -Throw '*PSResourceGet download failed*'

            Should -Invoke Install-Module -Times 3 -Exactly
            Should -Invoke Install-PSResource -Times 0 -Exactly
            Should -Invoke Start-Sleep -Times 2 -Exactly
            Should -Invoke Import-Module -Times 0 -Exactly
            Should -Invoke avm -Times 0 -Exactly
        }
    }
    if ($SupportsWorkflowAuthoringSource) {
        It 'loads the workflow checkout without contacting the Gallery' {
            $env:USE_WORKFLOW_AUTHORING_SOURCE = 'true'
            $sourceManifest = Join-Path $env:GITHUB_WORKSPACE 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
            Mock Install-PSResource {
                throw [System.Net.Http.HttpRequestException]::new('Gallery HTTP 403 (Forbidden).')
            }

            & $installer

            Should -Invoke Install-PSResource -Times 0 -Exactly
            Should -Invoke Install-Module -Times 0 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
            Should -Invoke Write-Warning -Times 0 -Exactly
            Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter {
                $Name -eq $sourceManifest -and $Force -and $ErrorAction -eq 'Stop'
            }
        }

        It 'reports a missing checkout module without falling back to the Gallery' {
            $env:USE_WORKFLOW_AUTHORING_SOURCE = 'true'
            $sourceManifest = Join-Path $env:GITHUB_WORKSPACE 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
            Mock Import-Module {
                throw [System.IO.FileNotFoundException]::new('Checkout module is missing.')
            } -ParameterFilter { $Name -eq $sourceManifest }

            { & $installer } | Should -Throw '*Checkout module is missing*'

            Should -Invoke Install-PSResource -Times 0 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
            Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq $sourceManifest }
        }

        It 'rejects an incompatible checkout without falling back to a release' {
            $env:USE_WORKFLOW_AUTHORING_SOURCE = 'true'
            Mock Get-Command {
                [pscustomobject]@{ Parameters = @{} }
            } -ParameterFilter { $Name -eq 'Invoke-AvmPreCommit' }

            { & $installer } | Should -Throw '*does not support repository sync options*'

            Should -Invoke Install-PSResource -Times 0 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'still rejects an incompatible release without retrying the successful installation' {
            Mock Get-Command {
                [pscustomobject]@{ Parameters = @{} }
            } -ParameterFilter { $Name -eq 'Invoke-AvmPreCommit' }

            { & $installer } | Should -Throw '*does not support repository sync options*'

            Should -Invoke Install-PSResource -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }
}
