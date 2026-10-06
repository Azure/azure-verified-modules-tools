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
        $bicep.Count | Should -Be 5
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
}
