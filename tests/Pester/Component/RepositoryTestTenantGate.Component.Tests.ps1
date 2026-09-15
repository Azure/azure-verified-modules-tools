BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:driver = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositorySync.ps1'
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

Describe 'Repository sync activation gate' -Tag Component {
    BeforeEach {
        $script:previousAzureAdFlag = $env:ARM_USE_AZUREAD
        $script:terraformRoot = Join-Path $TestDrive ('terraform-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:terraformRoot
        $script:configPath = Join-Path $TestDrive 'repository-config.json'
        $script:config = @{
            repositoryGroups = @(@{ name = 'default'; order = -1; repositories = @('*'); testTenant = 'bami' })
        }
        $script:config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:configPath
        $script:arguments = @{
            repoId = 'avm-ptn-example-repo'
            repoUrl = 'https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo'
            repoConfigFilePath = $script:configPath
            terraformModulePath = $script:terraformRoot
            outputDirectory = $TestDrive
        }
        Mock Start-Process { throw [System.InvalidOperationException]::new('ordinary-sync-process-boundary') }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring { throw [System.InvalidOperationException]::new('candidate-sync-process-boundary') }
    }

    AfterEach {
        if ($null -eq $script:previousAzureAdFlag) {
            Remove-Item Env:\ARM_USE_AZUREAD -ErrorAction SilentlyContinue
        }
        else {
            $env:ARM_USE_AZUREAD = $script:previousAzureAdFlag
        }
    }

    It 'preserves <InitialTenant> with gate <Gate> and PlanOnly <PlanOnly>' -TestCases @(
        @{ InitialTenant = 'legacy'; Gate = 'absent'; PlanOnly = $false }
        @{ InitialTenant = 'legacy'; Gate = 'false'; PlanOnly = $false }
        @{ InitialTenant = 'legacy'; Gate = 'absent'; PlanOnly = $true }
        @{ InitialTenant = 'legacy'; Gate = 'false'; PlanOnly = $true }
        @{ InitialTenant = 'bami'; Gate = 'absent'; PlanOnly = $false }
        @{ InitialTenant = 'bami'; Gate = 'false'; PlanOnly = $false }
        @{ InitialTenant = 'bami'; Gate = 'absent'; PlanOnly = $true }
        @{ InitialTenant = 'bami'; Gate = 'false'; PlanOnly = $true }
    ) {
        param($InitialTenant, $Gate, $PlanOnly)

        $priorSettings = @{
            ARM_TENANT_ID = "$InitialTenant-tenant"
            ARM_CLIENT_ID = "$InitialTenant-repository-client"
            TEST_SUBSCRIPTION_IDS = "$InitialTenant-subscriptions"
        }
        $variablesPath = Join-Path $script:terraformRoot 'terraform.tfvars.json'
        $priorSettings | ConvertTo-Json | Set-Content -LiteralPath $variablesPath
        $before = (Get-FileHash -LiteralPath $variablesPath -Algorithm SHA256).Hash
        $script:arguments.planOnly = $PlanOnly
        if ($Gate -eq 'false') { $script:arguments.bamiTestTenantSyncEnabled = $false }

        $result = & $script:driver @script:arguments

        $result.Status | Should -BeExactly 'PendingTestTenantActivation'
        $result.TestTenant | Should -BeExactly 'bami'
        (Get-FileHash -LiteralPath $variablesPath -Algorithm SHA256).Hash | Should -BeExactly $before
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'continues the ordinary path for explicit legacy with PlanOnly <PlanOnly>' -TestCases @(
        @{ PlanOnly = $false }
        @{ PlanOnly = $true }
    ) {
        param($PlanOnly)

        $script:config.repositoryGroups[0].testTenant = 'legacy'
        $script:config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:configPath
        $script:arguments.planOnly = $PlanOnly
        $script:arguments.bamiTestTenantSyncEnabled = $false

        { & $script:driver @script:arguments } | Should -Throw '*ordinary-sync-process-boundary*'
        Should -Invoke Start-Process -Exactly 1 -ParameterFilter { $FilePath -eq 'gh' }
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'does not gate repository creation, which does not publish test secrets' {
        $script:arguments.repositoryCreationModeEnabled = $true
        { & $script:driver @script:arguments } | Should -Throw '*ordinary-sync-process-boundary*'
        Should -Invoke Start-Process -Exactly 1 -ParameterFilter { $FilePath -eq 'terraform' }
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }
}
