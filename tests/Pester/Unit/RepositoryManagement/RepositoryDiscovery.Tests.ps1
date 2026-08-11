BeforeAll {
    $script:repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot ".." ".." ".." ".."
    )).Path
    $script:discoveryScript = Join-Path $script:repoRoot (
        "repository-management/repository-sync/actions/avm-repos/scripts/" +
        "Get-RepositoriesWhereAppInstalled.ps1"
    )

    function global:gh {
        $global:repositoryDiscoveryGhResponse
    }

    function New-TestRepository {
        param(
            [Parameter(Mandatory)]
            [string]$Name
        )

        [pscustomobject]@{
            name      = $Name
            full_name = "Azure/$Name"
            html_url  = "https://github.com/Azure/$Name"
            archived  = $false
        }
    }

    function Invoke-RepositoryDiscovery {
        param(
            [Parameter(Mandatory)]
            [array]$InstalledRepositories,

            [hashtable]$Parameters = @{}
        )

        $global:repositoryDiscoveryGhResponse = @{
            repositories = @($InstalledRepositories)
            total_count  = @($InstalledRepositories).Count
        } | ConvertTo-Json -Depth 5 -Compress

        & $script:discoveryScript `
            -outputDirectory $TestDrive `
            -metaDataFilePath $script:metaDataFilePath `
            @Parameters
    }
}

AfterAll {
    Remove-Item Function:\global:gh -Force
    Remove-Variable repositoryDiscoveryGhResponse -Scope Global -ErrorAction SilentlyContinue
}

Describe "Repository discovery built-in exclusions" {
    BeforeEach {
        $script:metaDataFilePath = Join-Path $TestDrive "repository-metadata.csv"
        @(
            "moduleId,isArchived"
            "avm-res-normal,false"
            "avm-res-custom,false"
        ) | Set-Content -LiteralPath $script:metaDataFilePath
        Remove-Item (Join-Path $TestDrive "issues.log.json") -ErrorAction SilentlyContinue
    }

    It "applies built-in exclusions when no additional parameter is supplied" {
        $repositories = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name "terraform-azurerm-avm-template")
                (New-TestRepository -Name "avm-terraform-governance")
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            )
        )

        $repositories.repoName | Should -Be @("terraform-azurerm-avm-res-normal")
    }

    It "applies built-in exclusions when the additional parameter is explicitly empty" {
        $repositories = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name "terraform-azurerm-avm-template")
                (New-TestRepository -Name "avm-terraform-governance")
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            ) -Parameters @{
                additionalReposToSkip = @()
            }
        )

        $repositories.repoName | Should -Be @("terraform-azurerm-avm-res-normal")
    }

    It "adds caller-supplied exclusions to the built-in exclusions" {
        $repositories = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name "terraform-azurerm-avm-template")
                (New-TestRepository -Name "avm-terraform-governance")
                (New-TestRepository -Name "terraform-azurerm-avm-res-custom")
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            ) -Parameters @{
                additionalReposToSkip = @("terraform-azurerm-avm-res-custom")
            }
        )

        $repositories.repoName | Should -Be @("terraform-azurerm-avm-res-normal")
    }

    It "matches built-in exclusions case-insensitively" {
        $repositories = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name "TERRAFORM-AZURERM-AVM-TEMPLATE")
                (New-TestRepository -Name "AVM-TERRAFORM-GOVERNANCE")
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            )
        )

        $repositories.repoName | Should -Be @("terraform-azurerm-avm-res-normal")
    }

    It "includes a normal repository" {
        $repositories = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            )
        )

        $repositories | Should -HaveCount 1
        $repositories[0].repoId | Should -Be "avm-res-normal"
        $repositories[0].repoName | Should -Be "terraform-azurerm-avm-res-normal"
    }
}
