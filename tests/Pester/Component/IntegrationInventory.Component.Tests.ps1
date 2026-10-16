#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Terraform acceptance discovery' -Tag Component {
    BeforeAll {
        $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    }

    AfterAll { Remove-Module Avm.Authoring -Force }

    It 'runs both canonical flows and exactly one migration without nested Pester state or overlapping selection' {
        $inventories = @{}
        foreach ($fixture in @('', 'terraform-azure-avm-res-mock', 'terraform-azurerm-avm-res-mock')) {
            $result = & (Get-Module Avm.Authoring) {
                param($Root, $Fixture, $PesterVersion)
                Invoke-AvmProcess -FilePath ([Environment]::ProcessPath) -ArgumentList @(
                    '-NoProfile', '-NonInteractive', '-File',
                    (Join-Path $Root 'tests' 'fixtures' 'tools' 'Get-IntegrationInventory.ps1'),
                    '-RepositoryRoot', $Root, '-PesterVersion', $PesterVersion, '-Fixture', $Fixture
                ) -WorkingDirectory $Root
            } $script:root $fixture (Get-Module Pester).Version.ToString()
            $inventories[$fixture] = @($result.StdOut | ConvertFrom-Json)
        }
        $azure = $inventories['terraform-azure-avm-res-mock']
        $azurerm = $inventories['terraform-azurerm-avm-res-mock']
        $azure | Should -HaveCount 2
        $azurerm | Should -HaveCount 1
        @($azure | Where-Object { $_ -in $azurerm }) | Should -HaveCount 0
        @(Compare-Object $inventories[''] @($azure + $azurerm)) | Should -HaveCount 0
        foreach ($fixture in @('terraform-azure-avm-res-mock', 'terraform-azurerm-avm-res-mock')) {
            @($inventories[$fixture] | Where-Object {
                    $_ -like '*keeps canonical bytes unchanged on both public pre-commit runs*'
                }) | Should -HaveCount 1
        }
    }
}
