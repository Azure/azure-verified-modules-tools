BeforeAll {
    $script:repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot '..' '..' '..' '..'
    )).Path
    . (Join-Path $script:repoRoot (
            'repository-management/repository-sync/scripts/lib/RetryHelpers.ps1'
        ))
    . (Join-Path $script:repoRoot (
            'repository-management/repository-sync/scripts/lib/TerraformOperations.ps1'
        ))
}

Describe 'Invoke-TerraformInit' {
    It 'uses upgrade for the local backend' {
        Mock Invoke-TerraformWithRetry {
            [pscustomobject]@{ success = $true }
        }

        $null = Invoke-TerraformInit `
            -terraformModulePath $TestDrive `
            -repositoryCreationModeEnabled $true `
            -repoId 'example' `
            -orgAndRepoName 'Azure/example' `
            -stateResourceGroupName 'rg' `
            -stateStorageAccountName 'storage' `
            -stateContainerName 'state' `
            -issueLog @()

        Should -Invoke Invoke-TerraformWithRetry -Exactly 1 -ParameterFilter {
            $commands[0].Arguments -join ' ' -eq 'init -upgrade'
        }
    }

    It 'uses upgrade before remote backend configuration arguments' {
        Mock Invoke-TerraformWithRetry {
            [pscustomobject]@{ success = $true }
        }

        $null = Invoke-TerraformInit `
            -terraformModulePath $TestDrive `
            -repositoryCreationModeEnabled $false `
            -repoId 'example' `
            -orgAndRepoName 'Azure/example' `
            -stateResourceGroupName 'rg' `
            -stateStorageAccountName 'storage' `
            -stateContainerName 'state' `
            -issueLog @()

        Should -Invoke Invoke-TerraformWithRetry -Exactly 1 -ParameterFilter {
            $commands[0].Arguments[0] -eq 'init' -and
            $commands[0].Arguments[1] -eq '-upgrade' -and
            $commands[0].Arguments[2] -like '-backend-config=*'
        }
    }
}
