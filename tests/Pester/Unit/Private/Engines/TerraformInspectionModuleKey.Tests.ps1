#Requires -Version 7.4

BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    Import-Module -Name $manifest -Force
}

AfterAll { Remove-Module -Name Avm.Authoring -Force }

Describe 'Terraform inspection module identity' {
    It 'normalizes exact public registry identities: <Source>' -ForEach @(
        @{ Source = 'Azure/naming/azurerm' }
        @{ Source = 'registry.terraform.io/Azure/naming/azurerm' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Source = $Source } {
            param($Source)
            Get-AvmTerraformInspectionModuleKey -Source $Source -Version '0.4.2' |
                Should -BeExactly 'registry.terraform.io/Azure/naming/azurerm@0.4.2'
        }
    }

    It 'does not reuse unproven selections: <Case>' -ForEach @(
        @{ Case = 'local'; Source = './module'; Version = '1.2.3' }
        @{ Case = 'private registry'; Source = 'private.example/Azure/naming/azurerm'; Version = '1.2.3' }
        @{ Case = 'Git'; Source = 'git::https://github.com/Azure/example.git?ref=v1'; Version = '1.2.3' }
        @{ Case = 'HTTP'; Source = 'https://example.com/module.zip'; Version = '1.2.3' }
        @{ Case = 'subdirectory'; Source = 'Azure/naming/azurerm//child'; Version = '1.2.3' }
        @{ Case = 'range'; Source = 'Azure/naming/azurerm'; Version = '~> 1.2' }
        @{ Case = 'operator'; Source = 'Azure/naming/azurerm'; Version = '= 1.2.3' }
        @{ Case = 'prerelease'; Source = 'Azure/naming/azurerm'; Version = '1.2.3-beta.1' }
        @{ Case = 'missing version'; Source = 'Azure/naming/azurerm'; Version = $null }
        @{ Case = 'leading zero'; Source = 'Azure/naming/azurerm'; Version = '01.2.3' }
        @{ Case = 'dynamic source'; Source = '${var.source}'; Version = '1.2.3' }
        @{ Case = 'invalid source shape'; Source = @{}; Version = '1.2.3' }
        @{ Case = 'invalid version shape'; Source = 'Azure/naming/azurerm'; Version = @(1, 2, 3) }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Source = $Source; Version = $Version } {
            param($Source, $Version)
            Get-AvmTerraformInspectionModuleKey -Source $Source -Version $Version | Should -BeNullOrEmpty
        }
    }
}
