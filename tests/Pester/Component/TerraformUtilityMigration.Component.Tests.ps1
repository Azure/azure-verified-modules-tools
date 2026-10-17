#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}
AfterAll { Remove-Module Avm.Authoring -Force }
Describe 'Terraform utility dependency inspection filesystem' -Tag Component {
BeforeEach {
        InModuleScope Avm.Authoring -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $script:utilityRoot = $Root
            $script:utilityOptions = [pscustomobject]@{
                ToolPath = 'mapotf'; TerraformPath = 'terraform'; EnvVars = @{}
                InspectionRoot = Join-Path $Root 'inspection'
                ProfileDirs    = @{ 'utility-module' = 'utility-profile' }
            }
            $script:utilityInspection = @{
                calls = @{}; variables = @{}; requirements = @{}
                resources = @{}; data_sources = @{}; ephemeral = @{}
            }
            $script:utilityTargets = @([pscustomobject]@{ Path = $Root; Scope = 'root'; Profiles = @('root', 'module', 'common') })
            Mock Get-AvmTerraformUtilityInspection { $script:utilityInspection }
            Mock Get-ChildItem { @() }
        }
    }
It 'proves target providers in an isolated wrapper and caches only that exact source and version' {
        InModuleScope Avm.Authoring {
            Mock Get-AvmTerraformUnitTestProviderSource {
                $Path | Should -Not -BeExactly $script:utilityRoot
                [System.IO.File]::ReadAllText((Join-Path $Path 'main.tf')) |
                    Should -Match 'version = "0.13.0"'
                @('registry.terraform.io/azure/azapi')
            }
            $call = [pscustomobject]@{ Source = 'Azure/avm-utl-regions/azurerm'; Version = '0.13.0'; Telemetry = $true }
            $cache = @{}
            @(Get-AvmTerraformUtilityProviderSource -Call $call -Options $script:utilityOptions -Cache $cache) |
                Should -Be @('registry.terraform.io/azure/azapi')
            $null = Get-AvmTerraformUtilityProviderSource -Call $call -Options $script:utilityOptions -Cache $cache
            Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 1
        }
    }
}
