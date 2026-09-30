#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-AvmTerraformRepositoryTarget' {
    It 'uses a valid folder name as the repository name' {
        $path = Join-Path $TestDrive 'terraform-azure-avm-ptn-alz-sub-vending2'
        $target = InModuleScope 'Avm.Authoring' -Parameters @{ Target = $path } {
            param($Target)
            Resolve-AvmTerraformRepositoryTarget -Path $Target -ModuleType pattern
        }

        $target.Root | Should -Be $path
        $target.Name | Should -BeExactly 'terraform-azure-avm-ptn-alz-sub-vending2'
        $target.ModuleName | Should -BeExactly 'avm-ptn-alz-sub-vending2'
    }

    It 'rejects a repository whose kind does not match the module type' {
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ Target = (Join-Path $TestDrive 'terraform-azure-avm-utl-regions') } {
                param($Target)
                Resolve-AvmTerraformRepositoryTarget -Path $Target -ModuleType resource
            }
        } | Should -Throw '*avm-utl module, which does not match -ModuleType resource*'
    }

    It 'requires a repository-named folder when it cannot prompt' {
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ Target = (Join-Path $TestDrive 'code') } {
                param($Target)
                Mock Test-AvmInteractiveHost { $false }
                Resolve-AvmTerraformRepositoryTarget -Path $Target -ModuleType resource
            }
        } | Should -Throw '*folder name must be the repository name*'
    }

    It 'asks for the repository name and places it beneath the given folder' {
        $parent = Join-Path $TestDrive 'code'
        $target = InModuleScope 'Avm.Authoring' -Parameters @{ Target = $parent } {
            param($Target)
            Mock Test-AvmInteractiveHost { $true }
            Mock Read-Host { ' terraform-azure-avm-res-web-site ' }
            Resolve-AvmTerraformRepositoryTarget -Path $Target -ModuleType resource
        }

        $target.Root | Should -Be (Join-Path $parent 'terraform-azure-avm-res-web-site')
        $target.Name | Should -BeExactly 'terraform-azure-avm-res-web-site'
    }

    It 'rejects an invalid prompted name' {
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ Target = (Join-Path $TestDrive 'code') } {
                param($Target)
                Mock Test-AvmInteractiveHost { $true }
                Mock Read-Host { 'Terraform-Azure-AVM-res-web' }
                Resolve-AvmTerraformRepositoryTarget -Path $Target -ModuleType resource
            }
        } | Should -Throw "*'Terraform-Azure-AVM-res-web' is not an AVM Terraform repository name*"
    }

    It 'identifies an existing clone from its <Kind> origin' -TestCases @(
        @{ Kind = 'HTTPS'; Url = 'https://github.com/Azure/terraform-azure-avm-res-web-site.git' }
        @{ Kind = 'SSH'; Url = 'git@github.com:Azure/terraform-azure-avm-res-web-site.git' }
    ) {
        param($Kind, $Url)
        $clone = Join-Path $TestDrive "clone-$Kind"
        $null = New-Item -ItemType Directory -Path (Join-Path $clone '.git') -Force
        $target = InModuleScope 'Avm.Authoring' -Parameters @{ Target = $clone; Url = $Url } {
            param($Target, $Url)
            Mock Invoke-AvmGit -MockWith ({ [pscustomobject]@{ ExitCode = 0; StdOut = "$Url`n"; StdErr = '' } }.GetNewClosure())
            Resolve-AvmTerraformRepositoryTarget -Path $Target -ModuleType resource
        }

        $target.Root | Should -Be $clone
        $target.Name | Should -BeExactly 'terraform-azure-avm-res-web-site'
    }

    It 'rejects a clone of a repository outside the Azure organization' {
        $clone = Join-Path $TestDrive 'terraform-azure-avm-res-web-site'
        $null = New-Item -ItemType Directory -Path (Join-Path $clone '.git') -Force
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ Target = $clone } {
                param($Target)
                Mock Invoke-AvmGit { [pscustomobject]@{ ExitCode = 0; StdOut = 'https://github.com/someone/fork.git'; StdErr = '' } }
                Resolve-AvmTerraformRepositoryTarget -Path $Target -ModuleType resource
            }
        } | Should -Throw '*not of an Azure GitHub repository*'
    }
}
