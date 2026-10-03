BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'RepositoryCandidate.ps1')
    $script:tenant = '11111111-1111-4111-8111-111111111111'
    $script:client = '22222222-2222-4222-8222-222222222222'
    $script:subscription = '33333333-3333-4333-8333-333333333333'
    $script:repository = 'Azure/terraform-azurerm-avm-res-example'

    function New-TestRepositoryCandidate {
        param(
            [string]$Directory,
            [bool]$HasChanges = $true,
            [bool]$PlanOnly = $false,
            [string]$Phase = 'prepared'
        )

        $null = New-Item -ItemType Directory -Path $Directory -Force
        $data = @{
            schemaVersion = 1
            repository = $script:repository
            phase = $Phase
            defaultBranch = 'main'
            baseSha = 'a' * 40
            hasChanges = $HasChanges
            planOnly = $PlanOnly
        }
        if ($HasChanges) {
            $data.headSha = 'b' * 40
            $data.treeSha = '2' * 40
            $data.changedPaths = @('main.tf')
            $data.authoringSource = if ($PlanOnly) { 'checkout' } else { 'gallery' }
            $data.authoringVersion = '0.0.0'
            [System.IO.File]::WriteAllBytes((Join-Path $Directory 'candidate.tar'), [byte[]]@(1, 2, 3))
            [System.IO.File]::WriteAllBytes((Join-Path $Directory 'candidate.patch'), [byte[]]@(4, 5, 6))
            $settings = @{
                tenantId = $script:tenant
                clientId = $script:client
                subscriptions = @(@{ name = 'test'; id = $script:subscription })
            }
            [System.IO.File]::WriteAllText((Join-Path $Directory 'test-settings.json'), ($settings | ConvertTo-Json -Depth 6))
        }
        [System.IO.File]::WriteAllText((Join-Path $Directory 'candidate.json'), ($data | ConvertTo-Json -Depth 6))
    }
}

Describe 'Repository sync test identity selection' {
    BeforeEach {
        $script:directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:directory
        $script:settings = @{
            tenant_id = $script:tenant
            client_id = $script:client
            test_subscription_ids = @(@{ name = 'test'; id = $script:subscription })
        }
    }

    It 'writes the identity and subscriptions from the planned effective output' {
        $plan = @{ planned_values = @{ outputs = @{ test_settings = @{ value = $script:settings } } } }
        Save-RepositorySyncCandidateTestSettings -Plan $plan -Directory $script:directory
        $settings = Read-RepositorySyncTestSettings -Directory $script:directory
        $settings.tenantId | Should -BeExactly $script:tenant
        $settings.clientId | Should -BeExactly $script:client
        $settings.subscriptions | Should -HaveCount 1
        $settings.subscriptions[0].id | Should -BeExactly $script:subscription
    }

    It 'fails explicitly when identity federation output has not been rolled out' {
        { Save-RepositorySyncCandidateTestSettings -Plan @{ planned_values = @{ outputs = @{} } } `
            -Directory $script:directory } | Should -Throw '*test_settings output*'
    }

    It 'rejects missing, malformed and duplicate test subscriptions' {
        foreach ($subscriptions in @(
                @(),
                @(@{ name = 'test'; id = 'not-a-guid' }),
                @(@{ name = 'test'; id = $script:subscription }, @{ name = 'duplicate'; id = $script:subscription })
            )) {
            $script:settings.test_subscription_ids = $subscriptions
            { ConvertTo-RepositorySyncTestSettings -Settings $script:settings } | Should -Throw
        }
    }
}

Describe 'Repository candidate failure diagnostics' {
    It 'shows blocking lint findings with file and rule while retaining check errors' {
        $result = [pscustomobject]@{
            Status = 'error'
            Steps = @(
                [pscustomobject]@{
                    Step = 'lint'
                    Status = 'fail'
                    Error = $null
                    Result = [pscustomobject]@{
                        Issues = @(
                            [pscustomobject]@{
                                File = 'examples/default/main.tf'
                                Line = 9
                                Severity = 'warning'
                                Code = 'terraform_unused_required_providers'
                                Message = 'provider modtm is declared but not used'
                            },
                            [pscustomobject]@{
                                File = 'variables.tf'
                                Line = 11
                                Severity = 'notice'
                                Code = 'avm_interface_retry'
                                Message = 'non-failing notice'
                            }
                        )
                    }
                },
                [pscustomobject]@{
                    Step = 'check policy'
                    Status = 'error'
                    Error = "No value for required variable`nlocation"
                    Result = $null
                }
            )
        }
        $output = @(Format-RepositorySyncCandidateCheckResult -Check 'pr-check' -Result $result) -join "`n"
        $output | Should -Match 'Candidate pr-check: error'
        $output | Should -Match 'lint: fail'
        $output | Should -Match 'examples/default/main\.tf:9: \[warning\] \[terraform_unused_required_providers\]'
        $output | Should -Match 'check policy: error'
        $output | Should -Match 'No value for required variable location'
        $output | Should -Not -Match 'non-failing notice'
    }

    It 'shows the underlying unit diagnostic and distinguishes skipped suites from passes' {
        $failure = [pscustomobject]@{
            Status = 'fail'
            RunsTotal = 2
            RunsFailed = 1
            Issues = @([pscustomobject]@{
                    File = 'tests/unit/example.tftest.hcl'
                    Line = 17
                    Severity = 'error'
                    Code = ''
                    Message = 'Invalid Resource ID'
                })
        }
        $output = @(Format-RepositorySyncCandidateCheckResult -Check 'unit' -Result $failure) -join "`n"
        $output | Should -Match '2 test run\(s\); 1 failed'
        $output | Should -Match 'tests/unit/example\.tftest\.hcl:17: \[error\] Invalid Resource ID'

        $skipped = [pscustomobject]@{ Status = 'skipped'; RunsTotal = 0; RunsFailed = 0; Issues = @() }
        (@(Format-RepositorySyncCandidateCheckResult -Check 'unit' -Result $skipped) -join "`n") |
            Should -Match 'No unit tests ran; changed candidates require tests/unit/'
        @(Format-RepositorySyncCandidateCheckResult -Check 'unit' -Result ([pscustomobject]@{ Status = 'pass' })) |
            Should -BeNullOrEmpty
    }
}

Describe 'Repository sync candidate module identity' {
    It 'derives the configured module ID from each Terraform provider family' {
        foreach ($provider in @('azurerm', 'azure', 'azapi')) {
            Get-RepositorySyncCandidateRepoId -Repository "Azure/terraform-${provider}-avm-ptn-example" |
                Should -BeExactly 'avm-ptn-example'
        }
    }

    It 'rejects non-module repository names instead of inferring an unrelated file group' {
        { Get-RepositorySyncCandidateRepoId -Repository 'Azure/repository' } | Should -Throw '*valid AVM Terraform module ID*'
    }
}

Describe 'Repository sync candidate validation' {
    BeforeEach {
        $script:directory = Join-Path $TestDrive ('candidate-' + [guid]::NewGuid().ToString('N'))
        $script:receipt = Join-Path $TestDrive ('receipt-' + [guid]::NewGuid().ToString('N'))
        $script:prCheckEnvironment = $null
        New-TestRepositoryCandidate -Directory $script:directory -PlanOnly $true
        Mock Invoke-RepositorySyncProcess { [pscustomobject]@{ ExitCode = 0; StdErr = '' } }
        Mock Invoke-RepositoryGit {
            if ($Arguments[0] -eq 'write-tree' -or $Arguments[-1] -eq 'HEAD^{tree}') { return '2' * 40 }
            return ''
        }
        Mock Invoke-AvmPrCheck {
            $script:prCheckEnvironment = @{
                Client = $env:ARM_CLIENT_ID
                Tenant = $env:ARM_TENANT_ID
                Subscription = $env:ARM_SUBSCRIPTION_ID
                UseCli = $env:ARM_USE_CLI
                GhToken = $env:GH_TOKEN
                ManagedRepoId = $env:AVM_MANAGED_FILES_REPO_ID
                ManagedConfigDir = $env:AVM_MANAGED_FILES_CONFIG_LOCAL_PATH
            }
            [pscustomobject]@{ Status = 'pass'; Steps = @() }
        }
        Mock Invoke-AvmTestUnit { [pscustomobject]@{ Status = 'pass' } }
    }

    It 'validates a clean local tree using the module identity before issuing a receipt' {
        $originalClient = [System.Environment]::GetEnvironmentVariable('ARM_CLIENT_ID', 'Process')
        $originalGhToken = [System.Environment]::GetEnvironmentVariable('GH_TOKEN', 'Process')
        $originalManagedRepoId = [System.Environment]::GetEnvironmentVariable('AVM_MANAGED_FILES_REPO_ID', 'Process')
        $originalManagedConfigDir = [System.Environment]::GetEnvironmentVariable('AVM_MANAGED_FILES_CONFIG_LOCAL_PATH', 'Process')
        $env:GH_TOKEN = 'inherited-token-for-test'
        $env:AVM_MANAGED_FILES_REPO_ID = 'wrong-repo-id'
        $env:AVM_MANAGED_FILES_CONFIG_LOCAL_PATH = 'wrong-config-directory'
        try {
            $result = Invoke-RepositorySyncCandidateValidation -Repository $script:repository `
                -CandidateDirectory $script:directory -ReceiptDirectory $script:receipt `
                -CheckoutModulePath (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
            $result | Should -BeExactly 'Passed'
            Should -Invoke Invoke-AvmPrCheck -Exactly 1 -ParameterFilter { $SkipModuleVersionCheck }
            $script:prCheckEnvironment.Client | Should -BeExactly $script:client
            $script:prCheckEnvironment.Tenant | Should -BeExactly $script:tenant
            $script:prCheckEnvironment.Subscription | Should -BeExactly $script:subscription
            $script:prCheckEnvironment.UseCli | Should -BeExactly 'false'
            $script:prCheckEnvironment.GhToken | Should -BeNullOrEmpty
            $script:prCheckEnvironment.ManagedRepoId | Should -BeExactly 'avm-res-example'
            $script:prCheckEnvironment.ManagedConfigDir | Should -BeExactly (
                (Resolve-Path -LiteralPath (Join-Path $script:root 'repository-management' 'repository-config')).Path)
            Should -Invoke Invoke-AvmTestUnit -Exactly 1 -ParameterFilter { $SkipModuleVersionCheck }
            if ([string]::IsNullOrEmpty($originalClient)) {
                $env:ARM_CLIENT_ID | Should -BeNullOrEmpty
            } else {
                $env:ARM_CLIENT_ID | Should -BeExactly $originalClient
            }
            $env:GH_TOKEN | Should -BeExactly 'inherited-token-for-test'
            $env:AVM_MANAGED_FILES_REPO_ID | Should -BeExactly 'wrong-repo-id'
            $env:AVM_MANAGED_FILES_CONFIG_LOCAL_PATH | Should -BeExactly 'wrong-config-directory'
            $receipt = Get-Content -LiteralPath (Join-Path $script:receipt 'validation.json') -Raw | ConvertFrom-Json -AsHashtable
            $receipt.treeSha | Should -BeExactly ('2' * 40)
        }
        finally {
            [System.Environment]::SetEnvironmentVariable('GH_TOKEN', $originalGhToken, 'Process')
            [System.Environment]::SetEnvironmentVariable('AVM_MANAGED_FILES_REPO_ID', $originalManagedRepoId, 'Process')
            [System.Environment]::SetEnvironmentVariable('AVM_MANAGED_FILES_CONFIG_LOCAL_PATH', $originalManagedConfigDir, 'Process')
        }
    }

    It 'runs both checks but does not issue a receipt when pr-check fails' {
        $script:diagnostics = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:diagnostics.Add([string]$Object) }
        Mock Invoke-AvmPrCheck {
            [pscustomobject]@{
                Status = 'fail'
                Steps = @([pscustomobject]@{
                        Step = 'lint'
                        Status = 'fail'
                        Result = [pscustomobject]@{
                            Issues = @([pscustomobject]@{
                                    File = 'examples/default/main.tf'
                                    Line = 9
                                    Severity = 'warning'
                                    Code = 'terraform_unused_required_providers'
                                    Message = 'provider modtm is unused'
                                })
                        }
                    })
            }
        }
        { Invoke-RepositorySyncCandidateValidation -Repository $script:repository `
            -CandidateDirectory $script:directory -ReceiptDirectory $script:receipt `
            -CheckoutModulePath (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') } |
            Should -Throw '*pr-check=fail*'
        Should -Invoke Invoke-AvmTestUnit -Exactly 1
        ($script:diagnostics -join "`n") | Should -Match 'examples/default/main\.tf:9: \[warning\] \[terraform_unused_required_providers\]'
        Test-Path -LiteralPath (Join-Path $script:receipt 'validation.json') | Should -BeFalse
    }

    It 'does not issue a receipt when unit tests fail or are skipped' -ForEach @('fail', 'skipped') {
        $script:unitStatus = $_
        Mock Invoke-AvmTestUnit { [pscustomobject]@{ Status = $script:unitStatus } }
        { Invoke-RepositorySyncCandidateValidation -Repository $script:repository `
            -CandidateDirectory $script:directory -ReceiptDirectory $script:receipt `
            -CheckoutModulePath (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') } |
            Should -Throw "*unit=$script:unitStatus*"
        Test-Path -LiteralPath (Join-Path $script:receipt 'validation.json') | Should -BeFalse
    }

    It 'skips all checks for an unchanged module' {
        New-TestRepositoryCandidate -Directory $script:directory -HasChanges $false
        $result = Invoke-RepositorySyncCandidateValidation -Repository $script:repository `
            -CandidateDirectory $script:directory -ReceiptDirectory $script:receipt -CheckoutModulePath 'unused'
        $result | Should -BeExactly 'NoChange'
        Should -Invoke Invoke-AvmPrCheck -Times 0
        Should -Invoke Invoke-AvmTestUnit -Times 0
        Test-Path -LiteralPath (Join-Path $script:receipt 'validation.json') | Should -BeTrue
    }

    It 'does not turn incomplete preparation into a passing validation' {
        Set-RepositorySyncCandidatePhase -Directory $script:directory -Repository $script:repository `
            -Phase initializing -PlanOnly $true
        { Invoke-RepositorySyncCandidateValidation -Repository $script:repository `
            -CandidateDirectory $script:directory -ReceiptDirectory $script:receipt -CheckoutModulePath 'unused' } |
            Should -Throw '*preparation did not finish*'
        Test-Path -LiteralPath (Join-Path $script:receipt 'validation.json') | Should -BeFalse
    }
}

Describe 'Repository sync publication safety' {
    BeforeEach {
        $script:directory = Join-Path $TestDrive ('candidate-' + [guid]::NewGuid().ToString('N'))
        $script:receipt = Join-Path $TestDrive ('receipt-' + [guid]::NewGuid().ToString('N'))
        New-TestRepositoryCandidate -Directory $script:directory
        $candidate = Read-RepositorySyncCandidate -Directory $script:directory -Repository $script:repository
        Save-RepositorySyncValidationReceipt -Candidate $candidate -Directory $script:receipt
        Mock Invoke-RepositoryFileSync { throw 'The candidate should not be published.' }
    }

    It 'rejects a missing or mismatched validation receipt before publication' {
        [System.IO.File]::WriteAllText((Join-Path $script:receipt 'validation.json'), '{}')
        { Invoke-RepositorySyncCandidatePublication -Repository $script:repository `
            -CandidateDirectory $script:directory -ReceiptDirectory $script:receipt } |
            Should -Throw '*receipt does not match*'
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }

    It 'never publishes a plan-only candidate' {
        New-TestRepositoryCandidate -Directory $script:directory -PlanOnly $true
        $candidate = Read-RepositorySyncCandidate -Directory $script:directory -Repository $script:repository
        Save-RepositorySyncValidationReceipt -Candidate $candidate -Directory $script:receipt
        { Invoke-RepositorySyncCandidatePublication -Repository $script:repository `
            -CandidateDirectory $script:directory -ReceiptDirectory $script:receipt } |
            Should -Throw '*Plan-only candidates cannot be published*'
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }

    It 'rejects a patch that does not recreate the validated file tree before any push' {
        Mock Invoke-RepositoryFileSync {
            param($Prepare, $State, $ExpectedBaseSha)
            & $Prepare @{ Root = 'isolated-clone'; State = $State; BaseSha = $ExpectedBaseSha }
        }
        Mock Invoke-RepositoryGit {
            if ($Arguments[0] -eq 'write-tree') { return '3' * 40 }
            return ''
        }
        { Invoke-RepositorySyncCandidatePublication -Repository $script:repository `
            -CandidateDirectory $script:directory -ReceiptDirectory $script:receipt } |
            Should -Throw '*does not produce the validated Git tree*'
    }

    It 'skips publication when an unchanged candidate was validated' {
        New-TestRepositoryCandidate -Directory $script:directory -HasChanges $false
        $candidate = Read-RepositorySyncCandidate -Directory $script:directory -Repository $script:repository
        Save-RepositorySyncValidationReceipt -Candidate $candidate -Directory $script:receipt
        $result = Invoke-RepositorySyncCandidatePublication -Repository $script:repository `
            -CandidateDirectory $script:directory -ReceiptDirectory $script:receipt
        $result.Status | Should -BeExactly 'NoChange'
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }
}
