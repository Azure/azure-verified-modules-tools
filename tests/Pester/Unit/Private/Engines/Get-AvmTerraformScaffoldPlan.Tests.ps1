#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:metadata = [ordered]@{ moduleDisplayName = 'Storage Accounts'; moduleDescription = 'Deploys a Storage Account.' }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmTerraformScaffoldPlan' {
    It 'plans only the minimal module files and renders the header from metadata' {
        $root = Join-Path $TestDrive 'terraform-azure-avm-res-storage-storageaccount'
        $plans = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root; Metadata = $script:metadata } {
            param($Root, $Metadata)
            Get-AvmTerraformScaffoldPlan -Path $Root -Metadata $Metadata
        }

        $relative = @($plans | ForEach-Object { [System.IO.Path]::GetRelativePath($root, $_.Path).Replace('\', '/') })
        $relative | Should -Be @(
            '_header.md', 'examples/default/_header.md', 'examples/default/main.tf', 'examples/default/variables.tf',
            'main.tf', 'outputs.tf', 'terraform.tf', 'variables.tf', 'tests/.gitkeep'
        )
        ($plans | Where-Object { $_.Path -like '*_header.md' -and $_.Path -notlike '*examples*' }).Content |
            Should -BeExactly "# Storage Accounts`n`nDeploys a Storage Account.`n"
        ($plans | Where-Object { $_.Path -like '*.gitkeep' }).Content | Should -BeExactly ''
        foreach ($plan in $plans) {
            $plan.Original | Should -BeNullOrEmpty
            $plan.Content.Contains("`r") | Should -BeFalse
        }
        ($plans | Where-Object { $_.Path -like '*terraform.tf' }).Content | Should -Match '"Azure/azapi"'
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'never replaces existing files and skips .gitkeep when tests already exist' {
        $root = Join-Path $TestDrive 'existing'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'tests' 'unit') -Force
        [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), "# authored`n")
        [System.IO.File]::WriteAllText((Join-Path $root 'tests' 'unit' 'unit.tftest.hcl'), "run `"x`" {}`n")

        $plans = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root; Metadata = $script:metadata } {
            param($Root, $Metadata)
            Get-AvmTerraformScaffoldPlan -Path $Root -Metadata $Metadata
        }

        @($plans.Path) | Should -Not -Contain (Join-Path $root 'main.tf')
        @($plans | Where-Object { $_.Path -like '*.gitkeep' }) | Should -HaveCount 0
        @($plans) | Should -HaveCount 7
    }

    It 'rejects an existing scaffold path with different casing' {
        $root = Join-Path $TestDrive 'casing'
        $null = New-Item -ItemType Directory -Path $root -Force
        [System.IO.File]::WriteAllText((Join-Path $root 'Main.tf'), "# authored`n")

        {
            InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root; Metadata = $script:metadata } {
                param($Root, $Metadata)
                Get-AvmTerraformScaffoldPlan -Path $Root -Metadata $Metadata
            }
        } | Should -Throw '*exact casing*'
    }
}
