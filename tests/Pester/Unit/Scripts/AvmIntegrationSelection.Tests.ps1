#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    . (Join-Path $script:repositoryRoot 'build' 'AvmPesterSharding.ps1')
}

Describe 'Integration group selection' {
    It 'preserves the full inventory with no overlap between Bicep and Terraform groups' {
        $path = Join-Path $script:repositoryRoot 'tests' 'Pester' 'Integration'
        $all = @(Get-AvmIntegrationTestFile -Path $path)
        $bicep = @(Get-AvmIntegrationTestFile -Path $path -Group Bicep)
        $terraform = @(Get-AvmIntegrationTestFile -Path $path -Group Terraform)
        $all.Count | Should -BeGreaterThan 0
        $bicep.Count | Should -Be 6
        $bicep | Should -Contain (Join-Path $path 'BicepTestSubscriptionSelection.Integration.Tests.ps1')
        $terraform.Count | Should -BeGreaterThan 0
        @($bicep | Where-Object { $_ -in $terraform }) | Should -HaveCount 0
        @(Compare-Object $all @($bicep + $terraform)) | Should -HaveCount 0
        foreach ($file in $bicep) {
            Get-Content -LiteralPath $file -Raw | Should -Not -Match 'AVM_INTEGRATION_FIXTURE|Add-MpPreference|az login|Invoke-AvmTestE2e'
        }
    }

    It 'automatically includes a new Bicep file without title-based selection' {
        [IO.File]::WriteAllText((Join-Path $TestDrive 'BicepFuture.Tests.ps1'), '')
        [IO.File]::WriteAllText((Join-Path $TestDrive 'Shared.Tests.ps1'), '')
        @(Get-AvmIntegrationTestFile -Path "$TestDrive" -Group Bicep | Split-Path -Leaf) |
            Should -Be @('BicepFuture.Tests.ps1')
        @(Get-AvmIntegrationTestFile -Path "$TestDrive" -Group Terraform | Split-Path -Leaf) |
            Should -Be @('Shared.Tests.ps1')
    }

    It 'fails when a selected group is empty or unknown' {
        $empty = Join-Path $TestDrive 'empty'
        $null = New-Item -ItemType Directory -Path $empty
        { Get-AvmIntegrationTestFile -Path $empty -Group Bicep } | Should -Throw '*No integration test files*'
        { Get-AvmIntegrationTestFile -Path $empty -Group Wrong } | Should -Throw
    }

    It 'partitions telemetry scenarios across fixture jobs without losing or duplicating coverage' {
        $previous = [Environment]::GetEnvironmentVariable('AVM_INTEGRATION_FIXTURE', 'Process')
        try {
            $inventories = @{}
            foreach ($fixture in @('', 'terraform-azure-avm-res-mock', 'terraform-azurerm-avm-res-mock')) {
                [Environment]::SetEnvironmentVariable('AVM_INTEGRATION_FIXTURE', $fixture, 'Process')
                $configuration = New-PesterConfiguration
                $configuration.Run.Path = Join-Path $script:repositoryRoot 'tests' 'Pester' 'Integration' `
                    'MapotfTelemetryAlignment.Integration.Tests.ps1'
                $configuration.Run.SkipRun = $true
                $configuration.Run.PassThru = $true
                $configuration.Output.Verbosity = 'None'
                $discovery = Invoke-Pester -Configuration $configuration
                $discovery.FailedCount | Should -Be 0
                $blocks = [System.Collections.Generic.Queue[object]]::new()
                foreach ($block in $discovery.Containers[0].Blocks) { $blocks.Enqueue($block) }
                $tests = @(
                    while ($blocks.Count -gt 0) {
                        $block = $blocks.Dequeue()
                        foreach ($test in $block.Tests) {
                            ($test.Path -join '.') + ':' + (ConvertTo-Json -InputObject $test.Data -Compress -Depth 10)
                        }
                        foreach ($child in $block.Blocks) { $blocks.Enqueue($child) }
                    }
                )
                $tests.Count | Should -BeGreaterThan 0
                $inventories[$fixture] = $tests
            }
            $azure = $inventories['terraform-azure-avm-res-mock']
            $azurerm = $inventories['terraform-azurerm-avm-res-mock']
            @($azure | Where-Object { $_ -in $azurerm }) | Should -HaveCount 0
            @(Compare-Object $inventories[''] @($azure + $azurerm)) | Should -HaveCount 0
            foreach ($fixture in @('terraform-azure-avm-res-mock', 'terraform-azurerm-avm-res-mock')) {
                @($inventories[$fixture] | Where-Object { $_ -like '*preserves existing delegated fixture tests*' }) |
                    Should -HaveCount 1
                @($inventories[$fixture] | Where-Object { $_ -like '*fixture unit suite isolated*' }) |
                    Should -HaveCount 1
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('AVM_INTEGRATION_FIXTURE',
                $(if ($null -eq $previous) { [NullString]::Value } else { $previous }), 'Process')
        }
    }
}
