#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:Get-AzContext {
            [CmdletBinding()]
            param()
            throw 'Unmocked Azure context lookup.'
        }
        function script:Set-AzContext {
            [CmdletBinding(SupportsShouldProcess)]
            param($Context, $Subscription, $Tenant, $Scope)
            throw 'Unmocked Azure context change.'
        }
        function script:Invoke-AzRestMethod {
            [CmdletBinding()]
            param($Method, $Path, $Uri, $Payload)
            throw 'Unmocked Azure request.'
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep cleanup state and context' -Tag Component {
    BeforeEach {
        $script:statePath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        InModuleScope Avm.Authoring {
            $script:originalContext = [pscustomobject]@{
                Subscription = @{ Id = '00000000-0000-0000-0000-000000000003' }
                Tenant = @{ Id = '00000000-0000-0000-0000-000000000002' }
                Account = @{ Id = 'test-principal' }
                Environment = @{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/' }
            }
            $script:currentContext = $script:originalContext
            Mock Get-AzContext { $script:currentContext }
            Mock Set-AzContext {
                param($Context, $Subscription, $Tenant, $Scope)
                if ($Scope -ne 'Process') { throw 'Context must be process-scoped.' }
                if ($null -ne $Context) {
                    $script:currentContext = $Context
                }
                else {
                    $script:currentContext = [pscustomobject]@{
                        Subscription = @{ Id = $Subscription }
                        Tenant = @{ Id = $Tenant }
                        Account = @{ Id = 'test-principal' }
                        Environment = @{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/' }
                    }
                }
                $script:currentContext
            }
            Mock Write-AvmLog {}
            Mock Start-Sleep {}
            Mock Invoke-AvmProcess { throw 'Unexpected subprocess.' }
            Mock Invoke-AvmBicepCleanupLookup { throw 'Unexpected Azure lookup.' }
            Mock Remove-AvmBicepResource { throw 'Unexpected resource removal.' }
            Mock Remove-AvmBicepResourceRemainder { throw 'Unexpected post-removal.' }
        }
    }

    It 'writes a portable state file without credentials, parameters or outputs' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $created.State['Parameters'] = @{ password = 'do-not-persist-parameters' }
            $created.State['DeploymentOutputs'] = @{ connectionString = 'do-not-persist-output' }
            $created.State['AzureContext'] = @{ Token = 'do-not-persist-token' }
            $created.State['deployments'].Add(@{
                    id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/attempt'
                    status = 'Attempted'
                    preflightRejected = $false
                    response = @{ secret = 'do-not-persist-response' }
                })
            Save-AvmBicepCleanupState -State $created.State -Path $File
            $json = [System.IO.File]::ReadAllText($File)
            $json | Should -Not -Match 'do-not-persist|password|connectionString|AzureContext|response'
            $json | Should -Not -Match "`r"
            $bytes = [System.IO.File]::ReadAllBytes($File)
            $bytes[0] | Should -Be 123
            $read = Read-AvmBicepCleanupState -Path $File
            $read['deployments'].Count | Should -Be 1
            $read['deployments'][0]['status'] | Should -BeExactly 'Attempted'
            $read['resources'].Count | Should -Be 0
            if (-not $IsWindows) {
                $mode = [System.IO.File]::GetUnixFileMode($File)
                ($mode -band ([System.IO.UnixFileMode]::OtherRead -bor [System.IO.UnixFileMode]::GroupRead)) |
                    Should -Be 0
            }
        }
    }

    It 'never overwrites an existing caller-selected file during creation' {
        [System.IO.File]::WriteAllText($script:statePath, 'existing user content')
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            { New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                    -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                    -TenantId '00000000-0000-0000-0000-000000000002' } |
                Should -Throw -ExpectedMessage '*overwrite*'
            [System.IO.File]::ReadAllText($File) | Should -BeExactly 'existing user content'
        }
    }

    It 'retains the last valid file and removes its temporary file after a serialization failure' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $before = [System.IO.File]::ReadAllText($File)
            Mock ConvertTo-Json { throw 'Serialization failed' }
            { Save-AvmBicepCleanupState -State $created.State -Path $File } |
                Should -Throw -ExpectedMessage '*Serialization failed*'
            [System.IO.File]::ReadAllText($File) | Should -BeExactly $before
            @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($File)) -Filter '.avm-cleanup-*.tmp').Count |
                Should -Be 0
        }
    }

    It 'rejects another run and malformed state instead of silently creating a replacement' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $original = [System.IO.File]::ReadAllText($File)
            $created.State['runId'] = [guid]::NewGuid().ToString('N')
            { Save-AvmBicepCleanupState -State $created.State -Path $File } | Should -Throw -ExpectedMessage '*another run*'
            [System.IO.File]::ReadAllText($File) | Should -BeExactly $original
            [System.IO.File]::WriteAllText($File, $original.Replace('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1'))
            { Read-AvmBicepCleanupState -Path $File } | Should -Throw -ExpectedMessage '*duplicate properties*'
            [System.IO.File]::WriteAllText($File, $original.Replace('"schemaVersion":1', '"schemaVersion":true'))
            { Read-AvmBicepCleanupState -Path $File } | Should -Throw -ExpectedMessage '*version*'
        }
    }

    It 'does not create a state file when declined' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002' -WhatIf
            Test-Path -LiteralPath $File | Should -BeFalse
        }
    }

    It 'restores the original native context after a failing operation' {
        InModuleScope Avm.Authoring {
            { Invoke-AvmBicepAzureContext `
                    -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                    -TenantId '00000000-0000-0000-0000-000000000002' `
                    -ScriptBlock { throw 'Operation failed' } } |
                Should -Throw -ExpectedMessage '*Operation failed*'
            $script:currentContext.Subscription.Id | Should -BeExactly '00000000-0000-0000-0000-000000000003'
            Should -Invoke Set-AzContext -Exactly 2 -ParameterFilter { $Scope -eq 'Process' }
        }
    }

    It 'refuses to invoke the operation if selecting a context changes the account' {
        InModuleScope Avm.Authoring {
            $script:called = $false
            Mock Set-AzContext {
                param($Context)
                if ($null -ne $Context) { return $Context }
                [pscustomobject]@{
                    Subscription = @{ Id = '00000000-0000-0000-0000-000000000001' }
                    Tenant = @{ Id = '00000000-0000-0000-0000-000000000002' }
                    Account = @{ Id = 'other-principal' }
                    Environment = @{ Name = 'AzureCloud' }
                }
            }
            { Invoke-AvmBicepAzureContext `
                    -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                    -TenantId '00000000-0000-0000-0000-000000000002' `
                    -ScriptBlock { $script:called = $true } } |
                Should -Throw -ExpectedMessage '*existing account*'
            $script:called | Should -BeFalse
            Should -Invoke Set-AzContext -Exactly 1 -ParameterFilter { $null -ne $Context }
        }
    }

    It 'reports restoration failure as a fatal context error' {
        InModuleScope Avm.Authoring {
            Mock Set-AzContext {
                param($Context, $Subscription, $Tenant)
                if ($null -ne $Context) { throw 'Restore failed' }
                [pscustomobject]@{
                    Subscription = @{ Id = $Subscription }
                    Tenant = @{ Id = $Tenant }
                    Account = @{ Id = 'test-principal' }
                    Environment = @{ Name = 'AzureCloud' }
                }
            }
            $failure = $null
            try {
                Invoke-AvmBicepAzureContext -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                    -TenantId '00000000-0000-0000-0000-000000000002' -ScriptBlock {}
            }
            catch { $failure = $_ }
            $failure | Should -Not -BeNullOrEmpty
            $failure.FullyQualifiedErrorId | Should -BeLike 'AvmBicepContextRestoreFailed*'
        }
    }

    It 'requires Azure CLI and native identities to agree' {
        InModuleScope Avm.Authoring {
            $script:currentContext.Subscription.Id = '00000000-0000-0000-0000-000000000001'
            $script:cliPrincipal = 'test-principal'
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 0; StdErr = ''
                    StdOut = @{
                        id = '00000000-0000-0000-0000-000000000001'
                        tenantId = '00000000-0000-0000-0000-000000000002'
                        environmentName = 'AzureCloud'
                        state = 'Enabled'
                        user = @{ name = $script:cliPrincipal }
                    } | ConvertTo-Json -Depth 4
                }
            }
            Assert-AvmBicepAzureIdentity -AzPath fake-az `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $script:cliPrincipal = 'other-principal'
            { Assert-AvmBicepAzureIdentity -AzPath fake-az `
                    -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                    -TenantId '00000000-0000-0000-0000-000000000002' } |
                Should -Throw -ExpectedMessage '*same enabled subscription*'
        }
    }

    It 'persists removal before post-processing and retries only incomplete post-processing' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $resourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/account'
            $created.State['resources'].Add(@{
                    id = $resourceId; type = 'Microsoft.Storage/storageAccounts'
                    removed = $false; postProcessed = $false; metadataCaptured = $false
                    managedResourceGroupIds = @(); originalSoftDeleteFeatureState = ''
                })
            Save-AvmBicepCleanupState -State $created.State -Path $File
            $script:postCalls = 0
            $script:batchStatePath = $File
            Mock Remove-AvmBicepResource {}
            Mock Remove-AvmBicepResourceRemainder {
                $persisted = Read-AvmBicepCleanupState -Path $script:batchStatePath
                $persisted['resources'][0]['removed'] | Should -BeTrue
                $script:postCalls++
                if ($script:postCalls -eq 1) { throw 'Transient purge failure' }
            }
            $result = Remove-AvmBicepCleanupResourceBatch -State $created.State -StatePath $File -RetryLimit 2 -RetryInterval 0
            $result.Cleaned | Should -BeTrue
            Should -Invoke Remove-AvmBicepResource -Exactly 1
            Should -Invoke Remove-AvmBicepResourceRemainder -Exactly 2
            (Read-AvmBicepCleanupState -Path $File)['resources'][0]['postProcessed'] | Should -BeTrue
            $script:currentContext.Subscription.Id | Should -BeExactly '00000000-0000-0000-0000-000000000003'
        }
    }

    It 'stops dependency preflight before imports when a required module is missing' {
        InModuleScope Avm.Authoring {
            Mock Get-AvmBicepAzureRequirement {
                [pscustomobject]@{
                    Name = 'Az.Accounts'; MinimumVersion = '5.3.4'
                    Commands = @{ 'Get-AzContext' = @() }
                }
            }
            Mock Get-Module { @() }
            Mock Import-Module {}
            { Assert-AvmBicepAzureDependency } | Should -Throw -ExpectedMessage '*dependencies are missing*'
            Should -Invoke Import-Module -Exactly 0
            Should -Invoke Get-AzContext -Exactly 0
        }
    }

    It 'validates the selected module version and command parameter aliases' {
        InModuleScope Avm.Authoring {
            Mock Get-AvmBicepAzureRequirement {
                [pscustomobject]@{
                    Name = 'Az.Accounts'; MinimumVersion = '5.3.4'
                    Commands = @{ 'Get-AzContext' = @('LegacyName') }
                }
            }
            Mock Get-Module {
                param($ListAvailable)
                if ($ListAvailable) {
                    [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'5.3.4'; Path = 'fake-accounts.psd1' }
                }
            }
            Mock Import-Module {}
            Mock Get-Command {
                [pscustomobject]@{
                    ModuleName = 'Az.Accounts'; Version = [version]'5.3.4'
                    Parameters = @{ CurrentName = [pscustomobject]@{ Aliases = @('LegacyName') } }
                }
            }
            Assert-AvmBicepAzureDependency
            Should -Invoke Import-Module -Exactly 1 -ParameterFilter { $Name -eq 'fake-accounts.psd1' }
            Mock Get-Command {
                [pscustomobject]@{
                    ModuleName = 'Az.Accounts'; Version = [version]'5.3.4'
                    Parameters = @{}
                }
            }
            { Assert-AvmBicepAzureDependency } | Should -Throw -ExpectedMessage '*lacks parameter*'
        }
    }

    It 'runs post-removal for a child even when removing its parent already deleted it' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $group = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'
            foreach ($resource in ConvertTo-AvmBicepCleanupResource -ResourceIds @(
                    $group, "$group/providers/Microsoft.Storage/storageAccounts/account"
                )) {
                $created.State['resources'].Add(@{
                        id = $resource.resourceId; type = $resource.type
                        removed = $false; postProcessed = $false; metadataCaptured = $false
                        managedResourceGroupIds = @(); originalSoftDeleteFeatureState = ''
                    })
            }
            Save-AvmBicepCleanupState -State $created.State -Path $File
            Mock Remove-AvmBicepResource {}
            Mock Remove-AvmBicepResourceRemainder {}
            $result = Remove-AvmBicepCleanupResourceBatch -State $created.State -StatePath $File -RetryInterval 0
            $result.Cleaned | Should -BeTrue
            Should -Invoke Remove-AvmBicepResource -Exactly 1 -ParameterFilter { $Type -eq 'Microsoft.Resources/resourceGroups' }
            Should -Invoke Remove-AvmBicepResource -Exactly 0 -ParameterFilter { $Type -eq 'Microsoft.Storage/storageAccounts' }
            Should -Invoke Remove-AvmBicepResourceRemainder -Exactly 2
        }
    }

    It 'retains unresolved discovery in the saved outcome after cleaning known resources' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $script:deployment = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/attempt'
            $script:target = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/account'
            $created.State['deployments'].Add(@{ id = $script:deployment; status = 'Failed'; preflightRejected = $false })
            Save-AvmBicepCleanupState -State $created.State -Path $File
            Mock Assert-AvmBicepAzureDependency {}
            Mock Assert-AvmBicepAzureIdentity {}
            Mock Get-Command { [pscustomobject]@{ Source = 'fake-az' } }
            Mock Invoke-AzRestMethod {
                param($Path)
                if ($Path -like '*page=2') { throw [System.TimeoutException]::new('Lookup timed out') }
                [pscustomobject]@{
                    StatusCode = 200
                    Content = @{
                        value = @(@{ properties = @{
                                    provisioningOperation = 'Create'
                                    targetResource = @{ id = $script:target }
                                } })
                        nextLink = "$script:deployment/operations?page=2"
                    } | ConvertTo-Json -Depth 8
                }
            }
            Mock Remove-AvmBicepResource {}
            Mock Remove-AvmBicepResourceRemainder {}
            $result = Invoke-AvmBicepCleanup -StatePath $File `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002' `
                -SearchRetryInterval 0 -RemovalRetryInterval 0
            $result.Cleaned | Should -BeFalse
            $result.Pending | Should -Contain $script:deployment
            Should -Invoke Remove-AvmBicepResource -Exactly 1 -ParameterFilter { $ResourceId -eq $script:target }
            $saved = Read-AvmBicepCleanupState -Path $File
            $saved['status'] | Should -BeExactly 'CleanupPending'
            $saved['resources'][0]['postProcessed'] | Should -BeTrue
            $script:currentContext.Subscription.Id | Should -BeExactly '00000000-0000-0000-0000-000000000003'
        }
    }

    It 'blocks an unverified owned group and all of its discovered children' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $script:ownedGroup = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'
            $created.State['ownedResourceGroups'].Add(@{ id = $script:ownedGroup; runId = $created.State.runId })
            $created.State['deployments'].Add(@{
                    id = "$script:ownedGroup/providers/Microsoft.Resources/deployments/attempt"
                    status = 'Succeeded'; preflightRejected = $false
                })
            Save-AvmBicepCleanupState -State $created.State -Path $File
            Mock Assert-AvmBicepAzureDependency {}
            Mock Assert-AvmBicepAzureIdentity {}
            Mock Get-Command { [pscustomobject]@{ Source = 'fake-az' } }
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{
                    StatusCode = 200
                    Content = @{
                        value = @(@{ properties = @{
                                    provisioningOperation = 'Create'
                                    targetResource = @{ id = "$script:ownedGroup/providers/Microsoft.Storage/storageAccounts/account" }
                                } })
                    } | ConvertTo-Json -Depth 8
                }
            }
            Mock Invoke-AvmBicepCleanupLookup {
                [pscustomobject]@{ ResourceId = $script:ownedGroup; Tags = @{ 'avm-e2e-run-id' = 'foreign-run' } }
            }
            Mock Remove-AvmBicepResource {}
            Mock Remove-AvmBicepResourceRemainder {}
            $result = Invoke-AvmBicepCleanup -StatePath $File `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002' `
                -RemovalRetryLimit 1 -RemovalRetryInterval 0
            $result.Cleaned | Should -BeFalse
            $result.Pending | Should -Contain $script:ownedGroup
            Should -Invoke Remove-AvmBicepResource -Exactly 0
            Should -Invoke Remove-AvmBicepResourceRemainder -Exactly 0
        }
    }

    It 'retains unresolved deletion targets after retry exhaustion' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $resourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/account'
            $created.State['resources'].Add(@{
                    id = $resourceId; type = 'Microsoft.Storage/storageAccounts'
                    removed = $false; postProcessed = $false; metadataCaptured = $false
                    managedResourceGroupIds = @(); originalSoftDeleteFeatureState = ''
                })
            Save-AvmBicepCleanupState -State $created.State -Path $File
            Mock Remove-AvmBicepResource { throw 'Delete denied' }
            Mock Remove-AvmBicepResourceRemainder {}
            $result = Remove-AvmBicepCleanupResourceBatch -State $created.State -StatePath $File -RetryLimit 2 -RetryInterval 0
            $result.Cleaned | Should -BeFalse
            $result.Pending | Should -Contain $resourceId
            $result.Issues.Count | Should -Be 1
            Should -Invoke Remove-AvmBicepResource -Exactly 2
            (Read-AvmBicepCleanupState -Path $File)['resources'][0]['removed'] | Should -BeFalse
        }
    }

    It 'resolves caller-selected relative state paths against the PowerShell location' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            Push-Location -LiteralPath ([System.IO.Path]::GetDirectoryName($File))
            try {
                $relative = [System.IO.Path]::GetFileName($File)
                $created = New-AvmBicepCleanupState -Path $relative -Environment AzureCloud `
                    -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                    -TenantId '00000000-0000-0000-0000-000000000002'
                $created.Path | Should -BeExactly $File
                $created.State.status = 'CleanupPending'
                Save-AvmBicepCleanupState -State $created.State -Path $relative
                (Read-AvmBicepCleanupState -Path $relative).status | Should -BeExactly 'CleanupPending'
            }
            finally {
                Pop-Location
            }
        }
    }

    It 'does not replace state that disappears before an update' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            Remove-Item -LiteralPath $File
            { Save-AvmBicepCleanupState -State $created.State -Path $File } |
                Should -Throw -ExpectedMessage '*disappeared*'
            Test-Path -LiteralPath $File | Should -BeFalse
        }
    }

    It 'resumes persisted post-removal without repeating metadata capture or deletion' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $created.State.resources.Add(@{
                    id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Databricks/workspaces/workspace'
                    removed = $true; postProcessed = $false; metadataCaptured = $true
                    managedResourceGroupIds = @('/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/custom-managed')
                    originalSoftDeleteFeatureState = ''
                })
            Save-AvmBicepCleanupState -State $created.State -Path $File
            $resumed = Read-AvmBicepCleanupState -Path $File
            Mock Initialize-AvmBicepCleanupResource { throw 'Metadata must not be recaptured.' }
            Mock Remove-AvmBicepResourceRemainder {}
            $result = Remove-AvmBicepCleanupResourceBatch -State $resumed -StatePath $File -RetryLimit 1
            $result.Cleaned | Should -BeTrue
            Should -Invoke Initialize-AvmBicepCleanupResource -Exactly 0
            Should -Invoke Remove-AvmBicepResource -Exactly 0
            Should -Invoke Remove-AvmBicepResourceRemainder -Exactly 1 -ParameterFilter {
                $ManagedResourceGroupIds.Count -eq 1 -and $ManagedResourceGroupIds[0] -like '*/custom-managed'
            }
            (Read-AvmBicepCleanupState -Path $File).resources[0].postProcessed | Should -BeTrue
        }
    }

    It 'keeps a parent when child metadata cannot be captured' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $group = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'
            foreach ($resource in ConvertTo-AvmBicepCleanupResource -ResourceIds @(
                    $group, "$group/providers/Microsoft.Databricks/workspaces/workspace"
                )) {
                $created.State.resources.Add(@{
                        id = $resource.resourceId; type = $resource.type
                        removed = $false; postProcessed = $false; metadataCaptured = $false
                        managedResourceGroupIds = @(); originalSoftDeleteFeatureState = ''
                    })
            }
            Save-AvmBicepCleanupState -State $created.State -Path $File
            Mock Invoke-AvmBicepCleanupLookup { throw 'Metadata access denied' }
            $result = Remove-AvmBicepCleanupResourceBatch -State $created.State -StatePath $File -RetryLimit 1
            $result.Cleaned | Should -BeFalse
            $result.Pending.Count | Should -Be 2
            $result.Issues.Count | Should -Be 2
            Should -Invoke Remove-AvmBicepResource -Exactly 0
            Should -Invoke Remove-AvmBicepResourceRemainder -Exactly 0
            @((Read-AvmBicepCleanupState -Path $File).resources | Where-Object { $_.removed }).Count | Should -Be 0
        }
    }

    It 'does not delete a blocked child indirectly through its parent' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $group = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'
            $child = "$group/providers/Microsoft.Storage/storageAccounts/account"
            foreach ($resource in ConvertTo-AvmBicepCleanupResource -ResourceIds @($group, $child)) {
                $created.State.resources.Add(@{
                        id = $resource.resourceId; type = $resource.type
                        removed = $false; postProcessed = $false; metadataCaptured = $true
                        managedResourceGroupIds = @(); originalSoftDeleteFeatureState = ''
                    })
            }
            Save-AvmBicepCleanupState -State $created.State -Path $File
            $result = Remove-AvmBicepCleanupResourceBatch -State $created.State -StatePath $File `
                -BlockedResourceIds @($child) -RetryLimit 1
            $result.Cleaned | Should -BeFalse
            $result.Pending.Count | Should -Be 2
            Should -Invoke Remove-AvmBicepResource -Exactly 0
            Should -Invoke Remove-AvmBicepResourceRemainder -Exactly 0
        }
    }

    It 'propagates cancellation during <Phase> without retrying' -ForEach @(
        @{ Phase = 'metadata' }
        @{ Phase = 'remove' }
        @{ Phase = 'post' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath; Phase = $Phase } {
            param($File, $Phase)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $created.State.resources.Add(@{
                    id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/account'
                    removed = $false; postProcessed = $false; metadataCaptured = $false
                    managedResourceGroupIds = @(); originalSoftDeleteFeatureState = ''
                })
            Save-AvmBicepCleanupState -State $created.State -Path $File
            $script:cancelPhase = $Phase
            Mock Initialize-AvmBicepCleanupResource {
                param($Resource)
                if ($script:cancelPhase -eq 'metadata') { throw [System.OperationCanceledException]::new('Cleanup cancelled') }
                $Resource['metadataCaptured'] = $true
            }
            Mock Remove-AvmBicepResource {
                if ($script:cancelPhase -eq 'remove') { throw [System.OperationCanceledException]::new('Cleanup cancelled') }
            }
            Mock Remove-AvmBicepResourceRemainder {
                if ($script:cancelPhase -eq 'post') { throw [System.OperationCanceledException]::new('Cleanup cancelled') }
            }
            { Remove-AvmBicepCleanupResourceBatch -State $created.State -StatePath $File -RetryLimit 3 } |
                Should -Throw -ExpectedMessage '*Cleanup cancelled*'
            Should -Invoke Start-Sleep -Exactly 0
            Should -Invoke Initialize-AvmBicepCleanupResource -Exactly 1
            $saved = Read-AvmBicepCleanupState -Path $File
            $saved.resources[0].postProcessed | Should -BeFalse
            $saved.resources[0].removed | Should -Be ($Phase -eq 'post')
            $script:currentContext.Subscription.Id | Should -BeExactly '00000000-0000-0000-0000-000000000003'
        }
    }

    It 'stops the batch immediately when the native context cannot be restored' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $created.State.resources.Add(@{
                    id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/account'
                    removed = $false; postProcessed = $false; metadataCaptured = $false
                    managedResourceGroupIds = @(); originalSoftDeleteFeatureState = ''
                })
            Save-AvmBicepCleanupState -State $created.State -Path $File
            Mock Set-AzContext {
                param($Context, $Subscription, $Tenant)
                if ($null -ne $Context) { throw 'Restore failed' }
                [pscustomobject]@{
                    Subscription = @{ Id = $Subscription }; Tenant = @{ Id = $Tenant }
                    Account = @{ Id = 'test-principal' }; Environment = @{ Name = 'AzureCloud' }
                }
            }
            $failure = $null
            try { Remove-AvmBicepCleanupResourceBatch -State $created.State -StatePath $File -RetryLimit 3 }
            catch { $failure = $_ }
            $failure | Should -Not -BeNullOrEmpty
            $failure.FullyQualifiedErrorId | Should -BeLike 'AvmBicepContextRestoreFailed*'
            Should -Invoke Remove-AvmBicepResource -Exactly 0
            Should -Invoke Remove-AvmBicepResourceRemainder -Exactly 0
            Should -Invoke Start-Sleep -Exactly 0
            (Read-AvmBicepCleanupState -Path $File).resources[0].metadataCaptured | Should -BeFalse
        }
    }

    It 'selects the actual resource subscription and restores the caller after each phase' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $created.State.resources.Add(@{
                    id = '/subscriptions/00000000-0000-0000-0000-000000000004/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/account'
                    removed = $false; postProcessed = $false; metadataCaptured = $false
                    managedResourceGroupIds = @(); originalSoftDeleteFeatureState = ''
                })
            Save-AvmBicepCleanupState -State $created.State -Path $File
            Mock Remove-AvmBicepResource {
                $script:currentContext.Subscription.Id | Should -BeExactly '00000000-0000-0000-0000-000000000004'
            }
            Mock Remove-AvmBicepResourceRemainder {
                $script:currentContext.Subscription.Id | Should -BeExactly '00000000-0000-0000-0000-000000000004'
            }
            (Remove-AvmBicepCleanupResourceBatch -State $created.State -StatePath $File -RetryLimit 1).Cleaned |
                Should -BeTrue
            Should -Invoke Set-AzContext -Exactly 3 -ParameterFilter {
                $Subscription -eq '00000000-0000-0000-0000-000000000004' -and $Scope -eq 'Process'
            }
            $script:currentContext.Subscription.Id | Should -BeExactly '00000000-0000-0000-0000-000000000003'
        }
    }

    It 'checks CLI identity before lookup, deletion or purge in a selected subscription' {
        InModuleScope Avm.Authoring {
            Mock Get-Command { [pscustomobject]@{ Source = 'fake-az' } }
            Mock Invoke-AvmProcess {
                param($ArgumentList)
                if ($ArgumentList[0] -ne 'account') { throw 'No resource command is permitted.' }
                [pscustomobject]@{
                    ExitCode = 0; StdErr = ''
                    StdOut = @{
                        id = '00000000-0000-0000-0000-000000000003'
                        tenantId = '00000000-0000-0000-0000-000000000002'
                        environmentName = 'AzureCloud'; state = 'Enabled'
                        user = @{ name = 'different-principal-for-this-subscription' }
                    } | ConvertTo-Json -Depth 4
                }
            }
            foreach ($operation in @('show', 'delete', 'purge')) {
                { Invoke-AvmBicepCleanupCli -ArgumentList @('apim', $operation) } |
                    Should -Throw -ExpectedMessage '*same enabled subscription*'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 3 -ParameterFilter {
                $ArgumentList[0] -eq 'account' -and $ArgumentList[3] -eq '00000000-0000-0000-0000-000000000003'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -ne 'account' }
        }
    }

    It 'finishes verified cleanup and does not repeat completed removals when resumed' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $created = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $script:ownedGroup = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'
            $script:ownedRun = $created.State.runId
            $created.State.ownedResourceGroups.Add(@{ id = $script:ownedGroup; runId = $script:ownedRun })
            $created.State.deployments.Add(@{
                    id = "$script:ownedGroup/providers/Microsoft.Resources/deployments/attempt"
                    status = 'Succeeded'; preflightRejected = $false
                })
            Save-AvmBicepCleanupState -State $created.State -Path $File
            Mock Assert-AvmBicepAzureDependency {}
            Mock Assert-AvmBicepAzureIdentity {}
            Mock Get-Command { [pscustomobject]@{ Source = 'fake-az' } }
            Mock Get-AvmBicepDeploymentCleanupTarget {
                [pscustomobject]@{
                    ResourceIds = @("$script:ownedGroup/providers/Microsoft.Storage/storageAccounts/account")
                    Deployments = @(); Issues = @()
                }
            }
            Mock Invoke-AvmBicepCleanupLookup {
                @{ ResourceId = $script:ownedGroup; Tags = @{ 'avm-e2e-run-id' = $script:ownedRun } }
            }
            Mock Remove-AvmBicepResource {}
            Mock Remove-AvmBicepResourceRemainder {}
            $parameters = @{
                StatePath = $File
                SubscriptionId = '00000000-0000-0000-0000-000000000001'
                TenantId = '00000000-0000-0000-0000-000000000002'
                RemovalRetryLimit = 1
            }
            $first = Invoke-AvmBicepCleanup @parameters
            $first.Cleaned | Should -BeTrue
            $first.Pending.Count | Should -Be 0
            $first.Issues.Count | Should -Be 0
            $saved = Read-AvmBicepCleanupState -Path $File
            $saved.status | Should -BeExactly 'Complete'
            $saved.resources.Count | Should -Be 2
            @($saved.resources | Where-Object { -not $_.postProcessed }).Count | Should -Be 0
            (Invoke-AvmBicepCleanup @parameters).Cleaned | Should -BeTrue
            Should -Invoke Remove-AvmBicepResource -Exactly 1
            Should -Invoke Remove-AvmBicepResourceRemainder -Exactly 2
            $script:currentContext.Subscription.Id | Should -BeExactly '00000000-0000-0000-0000-000000000003'
        }
    }

    It 'refuses state for a different explicit <Field> before Azure preflight' -ForEach @(
        @{ Field = 'SubscriptionId' }
        @{ Field = 'TenantId' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath; Field = $Field } {
            param($File, $Field)
            $null = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $parameters = @{
                StatePath = $File
                SubscriptionId = '00000000-0000-0000-0000-000000000001'
                TenantId = '00000000-0000-0000-0000-000000000002'
            }
            $parameters[$Field] = '00000000-0000-0000-0000-000000000004'
            Mock Assert-AvmBicepAzureDependency { throw 'Unexpected dependency import.' }
            { Invoke-AvmBicepCleanup @parameters } | Should -Throw -ExpectedMessage '*explicitly selected subscription and tenant*'
            Should -Invoke Assert-AvmBicepAzureDependency -Exactly 0
            Should -Invoke Get-AzContext -Exactly 0
            (Read-AvmBicepCleanupState -Path $File).status | Should -BeExactly 'Pending'
        }
    }

    It 'refuses a cloud mismatch before discovery or state changes' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $null = New-AvmBicepCleanupState -Path $File -Environment AzureUSGovernment `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            Mock Assert-AvmBicepAzureDependency {}
            Mock Get-Command { [pscustomobject]@{ Source = 'fake-az' } }
            Mock Get-AvmBicepDeploymentCleanupTarget { throw 'Unexpected deployment lookup.' }
            { Invoke-AvmBicepCleanup -StatePath $File `
                    -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                    -TenantId '00000000-0000-0000-0000-000000000002' } |
                Should -Throw -ExpectedMessage '*different Azure cloud*'
            Should -Invoke Get-AvmBicepDeploymentCleanupTarget -Exactly 0
            Should -Invoke Remove-AvmBicepResource -Exactly 0
            (Read-AvmBicepCleanupState -Path $File).status | Should -BeExactly 'Pending'
            $script:currentContext.Subscription.Id | Should -BeExactly '00000000-0000-0000-0000-000000000003'
        }
    }

    It 'does not change state or contact Azure when cleanup is declined' {
        InModuleScope Avm.Authoring -Parameters @{ File = $script:statePath } {
            param($File)
            $null = New-AvmBicepCleanupState -Path $File -Environment AzureCloud `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002'
            $before = [System.IO.File]::ReadAllText($File)
            Mock Assert-AvmBicepAzureDependency { throw 'Unexpected dependency import.' }
            $result = Invoke-AvmBicepCleanup -StatePath $File `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002' -WhatIf
            $result.Status | Should -BeExactly 'skipped'
            $result.Cleaned | Should -BeFalse
            Should -Invoke Assert-AvmBicepAzureDependency -Exactly 0
            Should -Invoke Get-AzContext -Exactly 0
            [System.IO.File]::ReadAllText($File) | Should -BeExactly $before
        }
    }
}
