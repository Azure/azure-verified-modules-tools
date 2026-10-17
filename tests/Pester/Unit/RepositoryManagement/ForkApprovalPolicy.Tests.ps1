#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $lib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    . (Join-Path $lib 'RetryHelpers.ps1')
    . (Join-Path $lib 'ForkApprovalPolicy.ps1')
}

Describe 'Terraform repository fork workflow approval policy' {
    BeforeEach {
        $script:repository = 'Azure/terraform-azurerm-avm-ptn-example-repo'
        $script:policy = 'all_external_contributors'
        Mock Invoke-RepositoryGitHubApi {
            [pscustomobject]@{ approval_policy = $script:policy }
        }
        Mock Invoke-RepositoryGitHub {
            $script:policy = 'first_time_contributors'
        }
        Mock Write-Information {}
    }

    It 'changes only contributor approval and verifies the result from <CurrentPolicy>' -ForEach @(
        @{ CurrentPolicy = 'all_external_contributors' }
        @{ CurrentPolicy = 'first_time_contributors_new_to_github' }
    ) {
        $script:policy = $CurrentPolicy
        $result = Set-RepositoryForkApprovalPolicy -Repository $script:repository -Confirm:$false

        $result.Status | Should -BeExactly 'Updated'
        $result.Repository | Should -BeExactly $script:repository
        $result.PreviousApprovalPolicy | Should -BeExactly $CurrentPolicy
        $result.ApprovalPolicy | Should -BeExactly 'first_time_contributors'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 2 -ParameterFilter {
            $Endpoint -ceq 'repos/Azure/terraform-azurerm-avm-ptn-example-repo/actions/permissions/fork-pr-contributor-approval'
        }
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter {
            $MaxRetries -eq 0 -and -not $AsJson -and
            ($Arguments -join '|') -ceq (
                'api|--hostname|github.com|--method|PUT|' +
                '--header|Accept: application/vnd.github+json|' +
                '--header|X-GitHub-Api-Version: 2022-11-28|' +
                'repos/Azure/terraform-azurerm-avm-ptn-example-repo/actions/permissions/fork-pr-contributor-approval|' +
                '--raw-field|approval_policy=first_time_contributors'
            )
        }
    }

    It 'does not write when the desired setting is already present in plan mode <PlanOnly>' -ForEach @(
        @{ PlanOnly = $false }
        @{ PlanOnly = $true }
    ) {
        $script:policy = 'first_time_contributors'
        $result = Set-RepositoryForkApprovalPolicy -Repository $script:repository -PlanOnly $PlanOnly -Confirm:$false

        $result.Status | Should -BeExactly 'Unchanged'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 1
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'reports drift without writing in plan mode' {
        $result = Set-RepositoryForkApprovalPolicy -Repository $script:repository -PlanOnly $true -Confirm:$false

        $result.Status | Should -BeExactly 'Planned'
        $result.PreviousApprovalPolicy | Should -BeExactly 'all_external_contributors'
        $result.ApprovalPolicy | Should -BeExactly 'first_time_contributors'
        $script:policy | Should -BeExactly 'all_external_contributors'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 1
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'previews without any API calls with WhatIf' {
        $result = Set-RepositoryForkApprovalPolicy -Repository $script:repository -WhatIf

        $result.Status | Should -BeExactly 'Preview'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 0
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'is idempotent on the next synchronization' {
        $first = Set-RepositoryForkApprovalPolicy -Repository $script:repository -Confirm:$false
        $second = Set-RepositoryForkApprovalPolicy -Repository $script:repository -Confirm:$false

        $first.Status | Should -BeExactly 'Updated'
        $second.Status | Should -BeExactly 'Unchanged'
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1
    }

    It 'rejects an invalid response without guessing or writing: <Case>' -ForEach @(
        @{ Case = 'null'; Response = $null }
        @{ Case = 'missing policy'; Response = [pscustomobject]@{} }
        @{ Case = 'unknown policy'; Response = [pscustomobject]@{ approval_policy = 'none' } }
        @{ Case = 'wrong casing'; Response = [pscustomobject]@{ approval_policy = 'First_Time_Contributors' } }
        @{ Case = 'null policy'; Response = [pscustomobject]@{ approval_policy = $null } }
        @{ Case = 'boolean policy'; Response = [pscustomobject]@{ approval_policy = $false } }
        @{ Case = 'array policy'; Response = [pscustomobject]@{ approval_policy = @('first_time_contributors') } }
        @{ Case = 'string document'; Response = 'first_time_contributors' }
    ) {
        $script:response = $Response
        Mock Invoke-RepositoryGitHubApi { $script:response }

        { Set-RepositoryForkApprovalPolicy -Repository $script:repository -Confirm:$false } |
            Should -Throw '*invalid fork workflow approval policy*'
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'propagates a read failure without treating it as a missing setting: <Failure>' -ForEach @(
        @{ Failure = 'HTTP 403' }
        @{ Failure = 'HTTP 404' }
        @{ Failure = 'Invalid JSON' }
    ) {
        $script:failure = $Failure
        Mock Invoke-RepositoryGitHubApi { throw [System.InvalidOperationException]::new($script:failure) }

        { Set-RepositoryForkApprovalPolicy -Repository $script:repository -Confirm:$false } |
            Should -Throw "*$Failure*"
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'propagates a failed update without retrying or reporting success' {
        Mock Invoke-RepositoryGitHub { throw [System.InvalidOperationException]::new('HTTP 403') }

        { Set-RepositoryForkApprovalPolicy -Repository $script:repository -Confirm:$false } |
            Should -Throw '*HTTP 403*'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 1
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter { $MaxRetries -eq 0 }
    }

    It 'fails an unconfirmed update without writing again' {
        Mock Invoke-RepositoryGitHub {}

        { Set-RepositoryForkApprovalPolicy -Repository $script:repository -Confirm:$false } |
            Should -Throw '*did not confirm*'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 2
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1
    }

    It 'propagates failed readback after a successful update' {
        $script:reads = 0
        Mock Invoke-RepositoryGitHubApi {
            $script:reads++
            if ($script:reads -gt 1) { throw [System.InvalidOperationException]::new('Readback unavailable') }
            [pscustomobject]@{ approval_policy = $script:policy }
        }

        { Set-RepositoryForkApprovalPolicy -Repository $script:repository -Confirm:$false } |
            Should -Throw '*Readback unavailable*'
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1
    }

    It 'rejects repositories outside managed Terraform module scope: <Repository>' -ForEach @(
        @{ Repository = 'Azure/bicep-registry-modules' }
        @{ Repository = 'Azure/azure-verified-modules-tools' }
        @{ Repository = 'another-owner/terraform-azurerm-avm-ptn-example-repo' }
        @{ Repository = 'Azure/terraform-azurerm-avm-ptn-example-repo/actions' }
        @{ Repository = 'Azure/terraform-azurerm-avm-ptn-example-repo?setting=value' }
    ) {
        { Set-RepositoryForkApprovalPolicy -Repository $Repository -Confirm:$false } | Should -Throw
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 0
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'supports the existing Terraform naming families: <Provider>' -ForEach @(
        @{ Provider = 'azure' }
        @{ Provider = 'azurerm' }
        @{ Provider = 'azapi' }
    ) {
        $repository = "Azure/terraform-$Provider-avm-res-example"
        $script:policy = 'first_time_contributors'
        $result = Set-RepositoryForkApprovalPolicy -Repository $repository -Confirm:$false

        $result.Status | Should -BeExactly 'Unchanged'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 1 -ParameterFilter {
            $Endpoint -ceq "repos/$repository/actions/permissions/fork-pr-contributor-approval"
        }
    }
}
