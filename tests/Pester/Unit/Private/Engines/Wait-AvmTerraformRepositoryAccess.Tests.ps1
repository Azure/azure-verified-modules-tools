#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Wait-AvmTerraformRepositoryAccess' {
    BeforeEach {
        $script:wait = @{ Repository = 'Azure/terraform-azure-avm-res-web-site'; ModuleName = 'avm-res-web-site' }
    }

    It 'returns immediately when the <Requirement> requirement is already met' -TestCases @(
        @{ Requirement = 'PortalSetup' }
        @{ Requirement = 'Elevation' }
    ) {
        param($Requirement)
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Wait = $script:wait; Requirement = $Requirement } {
            param($Wait, $Requirement)
            Mock Invoke-AvmGitHubApi { @{ visibility = 'public'; permissions = @{ admin = $true } } }
            Mock Read-Host { throw 'No prompt expected.' }
            Wait-AvmTerraformRepositoryAccess @Wait -Requirement $Requirement
        }
        $result['visibility'] | Should -Be 'public'
    }

    It 'writes the portal answers and returns nothing when it cannot prompt' {
        $captured = InModuleScope 'Avm.Authoring' -Parameters @{ Wait = $script:wait } {
            param($Wait)
            $script:logLines = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-AvmGitHubApi { $null }
            Mock Test-AvmInteractiveHost { $false }
            Mock Read-Host { throw 'No prompt expected.' }
            Mock Write-AvmLog { $script:logLines.Add($Message) }
            $result = Wait-AvmTerraformRepositoryAccess @Wait -Requirement PortalSetup
            [pscustomobject]@{ Result = $result; Lines = $script:logLines.ToArray() }
        }

        $captured.Result | Should -BeNullOrEmpty
        $captured.Lines | Should -Contain '  1. Open https://repos.opensource.microsoft.com/orgs/Azure/repos/terraform-azure-avm-res-web-site'
        $captured.Lines | Should -Contain "       Project name: Azure Verified Module (Terraform) for 'avm-res-web-site'"
        ($captured.Lines -join "`n") | Should -Match "Uncheck 'Repository template' and 'Add \.gitignore'"
    }

    It 're-checks GitHub after each confirmation until elevation is complete' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Wait = $script:wait } {
            param($Wait)
            $script:checks = 0
            $script:answers = [System.Collections.Generic.Queue[string]]::new([string[]]@('maybe', 'yes', 'y'))
            Mock Invoke-AvmGitHubApi {
                $script:checks++
                @{ visibility = 'public'; permissions = @{ admin = ($script:checks -ge 3) } }
            }
            Mock Test-AvmInteractiveHost { $true }
            Mock Read-Host { $script:answers.Dequeue() }
            Mock Write-AvmLog {}
            Wait-AvmTerraformRepositoryAccess @Wait -Requirement Elevation
            Should -Invoke Read-Host -Exactly 3
            Should -Invoke Invoke-AvmGitHubApi -Exactly 3
            Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*administrator access*' }
        }
        $result['permissions']['admin'] | Should -BeTrue
    }

    It 'stops when the operator answers no' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Wait = $script:wait } {
            param($Wait)
            Mock Invoke-AvmGitHubApi { @{ visibility = 'private' } }
            Mock Test-AvmInteractiveHost { $true }
            Mock Read-Host { 'no' }
            Mock Write-AvmLog {}
            Wait-AvmTerraformRepositoryAccess @Wait -Requirement PortalSetup
        }
        $result | Should -BeNullOrEmpty
    }

    It 'asks for confirmation after creation even when GitHub already reports the repository as public' {
        InModuleScope 'Avm.Authoring' -Parameters @{ Wait = $script:wait } {
            param($Wait)
            Mock Invoke-AvmGitHubApi { @{ visibility = 'public' } }
            Mock Test-AvmInteractiveHost { $true }
            Mock Read-Host { 'yes' }
            Mock Write-AvmLog {}
            $null = Wait-AvmTerraformRepositoryAccess @Wait -Requirement PortalSetup -AlwaysPrompt
            Should -Invoke Read-Host -Exactly 1
        }
    }
}
