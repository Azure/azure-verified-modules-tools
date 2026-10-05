#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        $names = @(
            'Get-AzContext', 'Set-AzContext', 'Get-AzResource', 'Get-AzResourceGroup'
            'Get-AzResourceLock', 'Remove-AzResourceLock', 'Remove-AzResource', 'Remove-AzResourceGroup'
            'Invoke-AzRestMethod', 'Remove-AzDiagnosticSetting'
            'Get-AzDiskEncryptionSet', 'Remove-AzKeyVaultAccessPolicy'
            'Get-AzRoleAssignment', 'Remove-AzRoleAssignment'
            'Get-AzRoleEligibilityScheduleRequest', 'New-AzRoleEligibilityScheduleRequest'
            'Get-AzRoleAssignmentScheduleRequest', 'New-AzRoleAssignmentScheduleRequest'
            'Get-AzRecoveryServicesVaultProperty', 'Set-AzRecoveryServicesVaultProperty'
            'Get-AzRecoveryServicesBackupItem', 'Undo-AzRecoveryServicesBackupItemDeletion'
            'Disable-AzRecoveryServicesBackupProtection'
            'Get-AzDataProtectionBackupVault', 'Update-AzDataProtectionBackupVault'
            'Get-AzDataProtectionSoftDeletedBackupInstance', 'Undo-AzDataProtectionBackupInstanceDeletion'
            'Get-AzDataProtectionBackupInstance', 'Remove-AzDataProtectionBackupInstance'
            'Get-AzDataProtectionBackupPolicy', 'Remove-AzDataProtectionBackupPolicy'
            'Remove-AzDataProtectionBackupVault', 'Remove-AzOperationalInsightsWorkspace'
            'Get-AzMLWorkspace', 'Get-AzSubscription', 'Get-AzManagementGroupSubscription'
            'New-AzManagementGroupSubscription', 'Disable-AzSubscription'
            'Get-AzExpressRouteGateway', 'Remove-AzExpressRouteGateway'
            'Get-AzKeyVault', 'Remove-AzKeyVault'
            'Get-AzCognitiveServicesAccount', 'Remove-AzCognitiveServicesAccount'
        )
        foreach ($name in $names) {
            Set-Item -Path "Function:script:$name" -Value {
                [CmdletBinding(SupportsShouldProcess)]
                param(
                    [Parameter(ValueFromPipeline)] $InputObject,
                    $Name, $ResourceId, $Scope, $LockId, $LockName, $ResourceGroupName,
                    $SubscriptionId, $Method, $Path, $Uri, $Payload, $VaultId, $VaultName,
                    $ObjectId, $Item, $PrincipalId, $RequestType, $RoleDefinitionId,
                    $BackupManagementType, $WorkloadType, $SoftDeleteFeatureState,
                    $ImmutabilityState, $SoftDeleteState, $BackupInstanceName, $GroupName,
                    $Location, $Context, $Tenant,
                    [switch] $Force, [switch] $ForceDelete, [switch] $InRemovedState,
                    [switch] $RemoveRecoveryPoints, [switch] $ExpandProperties
                )
                process {
                    throw "Unexpected Azure call: $($MyInvocation.MyCommand.Name)"
                }
            }
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep workflow cleanup resource identity' {
    It 'parses <Label> without namespace-name ambiguity' -ForEach @(
        @{ Label = 'resource group'; Id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'; Type = 'Microsoft.Resources/resourceGroups' }
        @{ Label = 'tenant policy'; Id = '/providers/Microsoft.Authorization/policyDefinitions/policy'; Type = 'Microsoft.Authorization/policyDefinitions' }
        @{ Label = 'management group'; Id = '/providers/Microsoft.Management/managementGroups/group'; Type = 'Microsoft.Management/managementGroups' }
        @{ Label = 'subscription alias'; Id = '/providers/Microsoft.Subscription/aliases/alias'; Type = 'Microsoft.Subscription/aliases' }
        @{ Label = 'nested child'; Id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Sql/servers/server/databases/db'; Type = 'Microsoft.Sql/servers/databases' }
        @{ Label = 'extension'; Id = '/providers/Microsoft.Management/managementGroups/group/providers/Microsoft.Authorization/policyAssignments/policy'; Type = 'Microsoft.Authorization/policyAssignments' }
        @{ Label = 'provider-looking name'; Id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/Microsoft.Storage'; Type = 'Microsoft.Storage/storageAccounts' }
        @{ Label = 'third-party provider'; Id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Contoso.Service/accounts/account'; Type = 'Contoso.Service/accounts' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Id = $Id; Type = $Type } {
            param($Id, $Type)
            $result = @(ConvertTo-AvmBicepCleanupResource -ResourceIds @($Id))
            $result.Count | Should -Be 1
            $result[0].resourceId | Should -BeExactly $Id
            $result[0].type | Should -BeExactly $Type
        }
    }

    It 'rejects an unsafe or incomplete identifier: <Id>' -ForEach @(
        @{ Id = '/subscriptions/00000000-0000-0000-0000-000000000001' }
        @{ Id = '/subscriptions/not-a-guid/resourceGroups/test' }
        @{ Id = '/providers/Microsoft.Storage/storageAccounts' }
        @{ Id = '/providers/Microsoft.Storage/storageAccounts/../other' }
        @{ Id = '/providers/Microsoft.Storage/storageAccounts/name?api-version=1' }
        @{ Id = '/providers/Microsoft.Storage/storageAccounts/name/' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Id = $Id } {
            param($Id)
            { ConvertTo-AvmBicepCleanupResource -ResourceIds @($Id) } | Should -Throw
        }
    }

    It 'preserves dependency priorities, child order, and aliases last' {
        InModuleScope Avm.Authoring {
            $resources = @(
                @{ resourceId = '/alias'; type = 'Microsoft.Subscription/aliases' }
                @{ resourceId = '/group'; type = 'Microsoft.Resources/resourceGroups' }
                @{ resourceId = '/identity'; type = 'Microsoft.ManagedIdentity/userAssignedIdentities' }
                @{ resourceId = '/parent'; type = 'Contoso.Service/parents' }
                @{ resourceId = '/parent/child'; type = 'Contoso.Service/parents/children' }
                @{ resourceId = '/role'; type = 'Microsoft.Authorization/roleAssignments' }
                @{ resourceId = '/image'; type = 'Microsoft.VirtualMachineImages/imageTemplates' }
                @{ resourceId = '/lock'; type = 'Microsoft.Authorization/locks' }
            )
            $actual = @(Get-AvmBicepResourceRemovalOrder -ResourcesToOrder $resources)
            ($actual.resourceId -join ',') | Should -BeExactly '/lock,/image,/role,/identity,/group,/parent/child,/parent,/alias'
            @(Get-AvmBicepResourceRemovalOrder -ResourcesToOrder @()).Count | Should -Be 0
        }
    }
}

Describe 'Bicep workflow cleanup group absence' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:groupLookupFailure = [System.Exception]::new('Unclassified SDK lookup failure.')
            $script:groupSubscription = '00000000-0000-0000-0000-000000000001'
            Mock Get-AzResourceGroup { throw $script:groupLookupFailure }
            Mock Get-AzContext { @{ Subscription = @{ Id = $script:groupSubscription } } }
            Mock Invoke-AzRestMethod { throw 'Unexpected ARM verification.' }
        }
    }

    It 'confirms an unclassified named-group error using an exact ARM GET: <Category>' -ForEach @(
        @{ Category = 'CloseError' }, @{ Category = 'OperationStopped' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Category = $Category } {
            param($Category)
            $script:unclassifiedGroupError = [Management.Automation.ErrorRecord]::new(
                [Exception]::new('Unclassified SDK lookup failure.'), 'SdkGroupLookup',
                [Management.Automation.ErrorCategory]$Category, $null)
            Mock Get-AzResourceGroup { throw $script:unclassifiedGroupError }
            Mock Invoke-AzRestMethod {
                @{ StatusCode = 404; Content = '{"error":{"code":"ResourceGroupNotFound"}}' }
            }
            Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters @{ Name = 'test(one)' } |
                Should -BeNullOrEmpty
            Should -Invoke Get-AzResourceGroup -Exactly 1 -ParameterFilter { $Name -ceq 'test(one)' }
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter {
                $Method -ceq 'GET' -and $ErrorAction -eq 'Stop' -and
                $Path -ceq '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test%28one%29?api-version=2021-04-01'
            }
        }
    }

    It 'preserves successful native results without a second lookup' {
        InModuleScope Avm.Authoring {
            Mock Get-AzResourceGroup { @{ ResourceId = '/original'; Tags = @{ owner = 'original' } } }
            $result = Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters @{ Name = 'test' }
            $result.ResourceId | Should -BeExactly '/original'
            $result.Tags.owner | Should -BeExactly 'original'
            Should -Invoke Get-AzContext -Exactly 0
            Should -Invoke Invoke-AzRestMethod -Exactly 0
        }
    }

    It 'does not reinterpret a classified HTTP <Status> response' -ForEach @(
        @{ Status = 401 }
        @{ Status = 403 }
        @{ Status = 404 }
        @{ Status = 429 }
        @{ Status = 500 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Status = $Status } {
            param($Status)
            $script:groupLookupFailure = [Net.Http.HttpRequestException]::new(
                'Classified response.', $null, [Net.HttpStatusCode]$Status)
            if ($Status -eq 404) {
                Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters @{ Name = 'test' } |
                    Should -BeNullOrEmpty
            }
            else {
                { Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters @{ Name = 'test' } } |
                    Should -Throw -ExpectedMessage '*Classified response*'
            }
            Should -Invoke Invoke-AzRestMethod -Exactly 0
        }
    }

    It 'does not probe after <Label>' -ForEach @(
        @{ Label = 'authorization failure'; Fault = [UnauthorizedAccessException]::new('Blocked') }
        @{ Label = 'invalid input'; Fault = [ArgumentException]::new('Blocked') }
        @{ Label = 'timeout'; Fault = [TimeoutException]::new('Blocked') }
        @{ Label = 'cancellation'; Fault = [OperationCanceledException]::new('Blocked') }
        @{ Label = 'wrapped cancellation'; Fault = [Exception]::new('Blocked', [OperationCanceledException]::new()) }
        @{ Label = 'transport failure'; Fault = [Net.Http.HttpRequestException]::new('Blocked') }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Fault = $Fault } {
            param($Fault)
            $script:groupLookupFailure = $Fault
            { Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters @{ Name = 'test' } } |
                Should -Throw
            Should -Invoke Get-AzContext -Exactly 0
            Should -Invoke Invoke-AzRestMethod -Exactly 0
        }
    }

    It 'does not probe a plain exception classified as <Category>' -ForEach @(
        @{ Category = 'AuthenticationError' }, @{ Category = 'PermissionDenied' }
        @{ Category = 'SecurityError' }, @{ Category = 'ConnectionError' }
        @{ Category = 'OperationTimeout' }
        @{ Category = 'InvalidArgument' }, @{ Category = 'InvalidData' }
        @{ Category = 'InvalidResult' }, @{ Category = 'ParserError' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Category = $Category } {
            param($Category)
            $script:classifiedGroupError = [Management.Automation.ErrorRecord]::new(
                [Exception]::new('Classified failure.'), 'ClassifiedFailure',
                [Management.Automation.ErrorCategory]$Category, $null)
            Mock Get-AzResourceGroup { throw $script:classifiedGroupError }
            { Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters @{ Name = 'test' } } |
                Should -Throw
            Should -Invoke Get-AzContext -Exactly 0
            Should -Invoke Invoke-AzRestMethod -Exactly 0
        }
    }

    It 'fails when verification returns <Label>' -ForEach @(
        @{ Label = 'an existing group'; Status = 200; Content = '{"id":"/existing"}' }
        @{ Label = 'access denied'; Status = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
        @{ Label = 'an authorization-shaped 404'; Status = 404; Content = '{"error":{"code":"AuthorizationFailed"}}' }
        @{ Label = 'an unknown 404'; Status = 404; Content = '{"error":{"code":"NotFound"}}' }
        @{ Label = 'an empty 404'; Status = 404; Content = '' }
        @{ Label = 'a malformed 404'; Status = 404; Content = 'not-json' }
        @{ Label = 'a missing error code'; Status = 404; Content = '{}' }
        @{ Label = 'a rate limit'; Status = 429; Content = '{}' }
        @{ Label = 'a service failure'; Status = 500; Content = '{}' }
        @{ Label = 'a missing status'; Status = $null; Content = '{"error":{"code":"ResourceGroupNotFound"}}' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Status = $Status; Content = $Content } {
            param($Status, $Content)
            $script:groupVerification = @{ StatusCode = $Status; Content = $Content }
            Mock Invoke-AzRestMethod { $script:groupVerification }
            { Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters @{ Name = 'test' } } |
                Should -Throw
            Should -Invoke Invoke-AzRestMethod -Exactly 1
        }
    }

    It 'does not probe a different getter or a non-name-only query' {
        InModuleScope Avm.Authoring {
            Mock Get-AzResource { throw $script:groupLookupFailure }
            foreach ($parameters in @(@{}, @{ Name = @('one', 'two') }, @{ Name = 'test'; ExpandProperties = $true })) {
                { Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters $parameters } |
                    Should -Throw
            }
            { Invoke-AvmBicepCleanupLookup -Command Get-AzResource -Parameters @{ ResourceId = '/original' } } |
                Should -Throw
            Should -Invoke Get-AzContext -Exactly 0
            Should -Invoke Invoke-AzRestMethod -Exactly 0
        }
    }

    It 'rejects an invalid context subscription before REST: <Subscription>' -ForEach @(
        @{ Subscription = '' }
        @{ Subscription = 'not-a-guid' }
        @{ Subscription = '00000000-0000-0000-0000-000000000000' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Subscription = $Subscription } {
            param($Subscription)
            $script:groupSubscription = $Subscription
            { Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters @{ Name = 'test' } } |
                Should -Throw
            Should -Invoke Invoke-AzRestMethod -Exactly 0
        }
    }

    It 'rejects a named-group lookup that would target <Label>' -ForEach @(
        @{ Label = 'a child resource'; Name = 'test/providers/Microsoft.Compute/virtualMachines/other' }
        @{ Label = 'a different query'; Name = 'test?api-version=other' }
        @{ Label = 'a parent path'; Name = '../other' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Name = $Name } {
            param($Name)
            { Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters @{ Name = $Name } } |
                Should -Throw
            Should -Invoke Invoke-AzRestMethod -Exactly 0
        }
    }
}

Describe 'Bicep workflow cleanup locks and failures' {
    It 'never returns inherited or similarly prefixed foreign locks' {
        InModuleScope Avm.Authoring {
            $script:target = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/target'
            Mock Get-AzResourceLock {
                @(
                    [pscustomobject]@{ LockId = "$script:target/providers/Microsoft.Authorization/locks/one" }
                    [pscustomobject]@{ LockId = "$script:target/providers/Microsoft.Storage/storageAccounts/sa/providers/Microsoft.Authorization/locks/two" }
                    [pscustomobject]@{ LockId = "$($script:target)-foreign/providers/Microsoft.Authorization/locks/three" }
                    [pscustomobject]@{ LockId = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Authorization/locks/parent' }
                )
            }
            Mock Write-AvmLog {}
            $locks = @(Get-AvmBicepResourceLock -ResourceId $script:target)
            $locks.Count | Should -Be 2
            Should -Invoke Write-AvmLog -Exactly 2 -ParameterFilter { $Level -eq 'Warning' }
        }
    }

    It 'fails when a lock remains after the bounded wait' {
        InModuleScope Avm.Authoring {
            Mock Get-AvmBicepResourceLock { [pscustomobject]@{ LockId = '/target/providers/Microsoft.Authorization/locks/one' } }
            Mock Remove-AzResourceLock {}
            Mock Start-Sleep {}
            { Remove-AvmBicepResourceLock -ResourceId '/target' -RetryLimit 2 } |
                Should -Throw -ExpectedMessage '*locks remain*'
            Should -Invoke Remove-AzResourceLock -Exactly 1
            Should -Invoke Start-Sleep -Exactly 1
        }
    }

    It 'treats only a confirmed HTTP 404 lookup as absent' {
        InModuleScope Avm.Authoring {
            Mock Get-AzResourceGroup {
                throw [System.Net.Http.HttpRequestException]::new('Missing', $null, [System.Net.HttpStatusCode]::NotFound)
            }
            Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters @{ Name = 'test' } |
                Should -BeNullOrEmpty
            Mock Get-AzResourceGroup {
                throw [System.Net.Http.HttpRequestException]::new('Denied', $null, [System.Net.HttpStatusCode]::Forbidden)
            }
            { Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup -Parameters @{ Name = 'test' } } |
                Should -Throw -ExpectedMessage '*Denied*'
        }
    }

    It 'distinguishes timeouts, cancellation and transport failures' {
        InModuleScope Avm.Authoring {
            $cases = @(
                @{ Exception = [System.TimeoutException]::new('timeout'); Kind = 'Timeout' }
                @{ Exception = [System.OperationCanceledException]::new('cancel'); Kind = 'Cancellation' }
                @{ Exception = [System.Net.Http.HttpRequestException]::new('transport'); Kind = 'Transport' }
                @{ Exception = [System.OperationCanceledException]::new('timeout', [System.TimeoutException]::new('timeout')); Kind = 'Timeout' }
                @{ Exception = [System.AggregateException]::new([System.Exception[]]@([System.TimeoutException]::new(), [System.OperationCanceledException]::new())); Kind = 'Cancellation' }
            )
            foreach ($case in $cases) {
                $record = [System.Management.Automation.ErrorRecord]::new($case.Exception, 'test', 'NotSpecified', $null)
                Get-AvmBicepDeploymentErrorKind -ErrorRecord $record | Should -BeExactly $case.Kind
            }
        }
    }

    It 'follows Azure collection pages and refuses foreign pagination' {
        InModuleScope Avm.Authoring {
            $script:pageNumber = 0
            Mock Get-AzContext { [pscustomobject]@{ Environment = @{ ResourceManagerUrl = 'https://management.azure.com/' } } }
            Mock Invoke-AzRestMethod {
                $script:pageNumber++
                $content = if ($script:pageNumber -eq 1) {
                    @{ value = @(@{ id = 'first' }); nextLink = 'https://management.azure.com/collection?page=2' }
                }
                else { @{ value = @(@{ id = 'second' }) } }
                [pscustomobject]@{ StatusCode = 200; Content = $content | ConvertTo-Json -Depth 5 }
            }
            $items = @(Get-AvmBicepCleanupRestCollection -Path '/collection')
            ($items.id -join ',') | Should -BeExactly 'first,second'
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter { $Path -eq '/collection?page=2' }
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{
                    StatusCode = 200
                    Content    = '{"value":[],"nextLink":"https://untrusted.example/collection"}'
                }
            }
            { Get-AvmBicepCleanupRestCollection -Path '/collection' } |
                Should -Throw -ExpectedMessage '*foreign nextLink*'
        }
    }
}

Describe 'Bicep workflow cleanup native handlers' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:cleanupSubscription = '00000000-0000-0000-0000-000000000001'
            $script:cleanupGroup = "/subscriptions/$script:cleanupSubscription/resourceGroups/test"
            Mock Remove-AvmBicepResourceLock {}
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
        }
    }

    It 'retains parent-owned or dependency-owned resources: <Type>' -ForEach @(
        @{ Type = 'Microsoft.KeyVault/vaults/keys'; Suffix = 'vaults/vault/keys/key' }
        @{ Type = 'Microsoft.KeyVault/vaults/accessPolicies'; Suffix = 'vaults/vault/accessPolicies/add' }
        @{ Type = 'Microsoft.RecoveryServices/vaults/backupstorageconfig'; Suffix = 'vaults/vault/backupstorageconfig/default' }
        @{ Type = 'Microsoft.ServiceBus/namespaces/authorizationRules'; Suffix = 'namespaces/service/authorizationRules/RootManageSharedAccessKey' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Type = $Type; Suffix = $Suffix } {
            param($Type, $Suffix)
            Mock Remove-AzResource {}
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/$($Type.Split('/')[0])/$Suffix" -Type $Type
            Should -Invoke Remove-AzResource -Exactly 0
        }
    }

    It 'uses ordinary resource removal for a supported generic type' {
        InModuleScope Avm.Authoring {
            Mock Remove-AzResource {}
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.Storage/storageAccounts/test" `
                -Type 'Microsoft.Storage/storageAccounts'
            Should -Invoke Remove-AzResource -Exactly 1 -ParameterFilter {
                $Force -and $ResourceId -eq "$script:cleanupGroup/providers/Microsoft.Storage/storageAccounts/test"
            }
        }
    }

    It 'removes diagnostics at the exact parent scope' {
        InModuleScope Avm.Authoring {
            Mock Remove-AzDiagnosticSetting {}
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.Storage/storageAccounts/test/providers/Microsoft.Insights/diagnosticSettings/diag" `
                -Type 'Microsoft.Insights/diagnosticSettings'
            Should -Invoke Remove-AzDiagnosticSetting -Exactly 1 -ParameterFilter {
                $Name -eq 'diag' -and $ResourceId -eq "$script:cleanupGroup/providers/Microsoft.Storage/storageAccounts/test"
            }
        }
    }

    It 'removes the disk encryption identity access policy before its resource' {
        InModuleScope Avm.Authoring {
            $script:steps = [System.Collections.Generic.List[string]]::new()
            Mock Get-AzDiskEncryptionSet {
                [pscustomobject]@{
                    ActiveKey = @{ SourceVault = @{ Id = "$script:cleanupGroup/providers/Microsoft.KeyVault/vaults/vault" } }
                    Identity  = @{ PrincipalId = 'principal' }
                }
            }
            Mock Remove-AzKeyVaultAccessPolicy { $script:steps.Add('policy') }
            Mock Remove-AzResource { $script:steps.Add('resource') }
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.Compute/diskEncryptionSets/des" `
                -Type 'Microsoft.Compute/diskEncryptionSets'
            ($script:steps -join ',') | Should -BeExactly 'policy,resource'
            Should -Invoke Remove-AzKeyVaultAccessPolicy -Exactly 1 -ParameterFilter {
                $VaultName -eq 'vault' -and $ObjectId -eq 'principal'
            }
        }
    }

    It 'uses AdminRemove for <Type> rather than ordinary DELETE' -ForEach @(
        @{ Type = 'roleEligibilityScheduleRequests'; Read = 'Get-AzRoleEligibilityScheduleRequest'; Write = 'New-AzRoleEligibilityScheduleRequest' }
        @{ Type = 'roleAssignmentScheduleRequests'; Read = 'Get-AzRoleAssignmentScheduleRequest'; Write = 'New-AzRoleAssignmentScheduleRequest' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Type = $Type; Read = $Read; Write = $Write } {
            param($Type, $Read, $Write)
            Mock $Read { [pscustomobject]@{ PrincipalId = 'principal'; RoleDefinitionId = 'definition' } }
            Mock $Write {}
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.Authorization/$Type/request" `
                -Type "Microsoft.Authorization/$Type"
            Should -Invoke $Write -Exactly 1 -ParameterFilter {
                $RequestType -eq 'AdminRemove' -and $Scope -eq $script:cleanupGroup -and
                $PrincipalId -eq 'principal' -and $RoleDefinitionId -eq 'definition'
            }
            Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 300 }
        }
    }

    It 'undoes soft deletion and removes recovery points before deleting a vault' {
        InModuleScope Avm.Authoring {
            $script:steps = [System.Collections.Generic.List[string]]::new()
            Mock Get-AzRecoveryServicesVaultProperty { [pscustomobject]@{ SoftDeleteFeatureState = 'Enabled' } }
            Mock Set-AzRecoveryServicesVaultProperty { $script:steps.Add('disable-soft-delete') }
            Mock Get-AzRecoveryServicesBackupItem { [pscustomobject]@{ Name = 'item'; DeleteState = 'ToBeDeleted' } }
            Mock Undo-AzRecoveryServicesBackupItemDeletion { $script:steps.Add('undo') }
            Mock Disable-AzRecoveryServicesBackupProtection { $script:steps.Add('remove-points') }
            Mock Remove-AzResource { $script:steps.Add('vault') }
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.RecoveryServices/vaults/vault" `
                -Type 'Microsoft.RecoveryServices/vaults'
            ($script:steps -join ',') | Should -BeExactly 'disable-soft-delete,undo,remove-points,vault'
            Should -Invoke Disable-AzRecoveryServicesBackupProtection -Exactly 1 -ParameterFilter {
                $Force -and $RemoveRecoveryPoints
            }
        }
    }

    It 'removes Data Protection instances and policies before the vault' {
        InModuleScope Avm.Authoring {
            $script:steps = [System.Collections.Generic.List[string]]::new()
            Mock Get-AzDataProtectionBackupVault { [pscustomobject]@{ ImmutabilityState = 'Unlocked'; SoftDeleteState = 'On' } }
            Mock Update-AzDataProtectionBackupVault { $script:steps.Add('settings') }
            Mock Get-AzDataProtectionSoftDeletedBackupInstance { [pscustomobject]@{ Name = 'soft' } }
            Mock Undo-AzDataProtectionBackupInstanceDeletion { $script:steps.Add('undo') }
            Mock Get-AzDataProtectionBackupInstance { [pscustomobject]@{ Name = 'active' } }
            Mock Remove-AzDataProtectionBackupInstance { $script:steps.Add('instance') }
            Mock Get-AzDataProtectionBackupPolicy { [pscustomobject]@{ Name = 'policy' } }
            Mock Remove-AzDataProtectionBackupPolicy { $script:steps.Add('policy') }
            Mock Remove-AzDataProtectionBackupVault { $script:steps.Add('vault') }
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.DataProtection/backupVaults/vault" `
                -Type 'Microsoft.DataProtection/backupVaults'
            ($script:steps -join ',') | Should -BeExactly 'settings,settings,undo,instance,policy,vault'
        }
    }

    It 'handles a Log Analytics workspace with no replication property' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{ StatusCode = 200; Content = '{"location":"eastus","properties":{}}' }
            }
            Mock Remove-AzOperationalInsightsWorkspace {}
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.OperationalInsights/workspaces/workspace" `
                -Type 'Microsoft.OperationalInsights/workspaces'
            Should -Invoke Remove-AzOperationalInsightsWorkspace -Exactly 1 -ParameterFilter { $Force -and $ForceDelete }
        }
    }

    It 'waits for image template deletion and fails on exhaustion' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {
                param($Method)
                if ($Method -eq 'DELETE') {
                    return [pscustomobject]@{ StatusCode = 202; Content = '{}' }
                }
                [pscustomobject]@{ StatusCode = 200; Content = '{}' }
            }
            { Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.VirtualMachineImages/imageTemplates/image" `
                    -Type 'Microsoft.VirtualMachineImages/imageTemplates' } |
                Should -Throw -ExpectedMessage '*deletion did not finish*'
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter { $Method -eq 'DELETE' }
            Should -Invoke Invoke-AzRestMethod -Exactly 240 -ParameterFilter { $Method -eq 'GET' }
            Should -Invoke Start-Sleep -Exactly 239
        }
    }

    It 'force-purges ML workspaces and checks confirmed absence' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 202; Content = '{}' } }
            Mock Invoke-AvmBicepCleanupLookup { $null }
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.MachineLearningServices/workspaces/workspace" `
                -Type 'Microsoft.MachineLearningServices/workspaces'
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter {
                $Method -eq 'DELETE' -and $Path -like '*forceToPurge=true'
            }
            Should -Invoke Invoke-AvmBicepCleanupLookup -Exactly 1 -ParameterFilter { $Command -eq 'Get-AzMLWorkspace' }
        }
    }

    It 'preserves the special subscription decommissioning workflow' {
        InModuleScope Avm.Authoring {
            Mock Get-AzSubscription {
                [pscustomobject]@{ Name = 'dep-sub-blzv-tests-case'; Id = '00000000-0000-0000-0000-000000000003'; State = 'Enabled' }
            }
            Mock Set-AzContext {}
            Mock Invoke-AvmBicepCleanupLookup {
                param($Command)
                if ($Command -eq 'Get-AzResourceGroup') { return @{ Name = 'NetworkWatcherRG' } }
                $null
            }
            Mock Remove-AzResourceGroup {}
            Mock New-AzManagementGroupSubscription {}
            Mock Disable-AzSubscription {}
            Remove-AvmBicepResource -ResourceId '/providers/Microsoft.Subscription/aliases/dep-sub-blzv-tests-case' `
                -Type 'Microsoft.Subscription/aliases'
            Should -Invoke Set-AzContext -Exactly 1 -ParameterFilter { $Scope -eq 'Process' }
            Should -Invoke Remove-AzResourceGroup -Exactly 1 -ParameterFilter { $Name -eq 'NetworkWatcherRG' }
            Should -Invoke New-AzManagementGroupSubscription -Exactly 1 -ParameterFilter { $GroupName -eq 'bicep-lz-vending-automation-decom' }
            Should -Invoke Disable-AzSubscription -Exactly 1
        }
    }

    It 'uses checked CLI invocations for CDN deletion' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepCleanupCli {
                param($ArgumentList)
                if ($ArgumentList -contains 'show') { return '{"name":"profile"}' }
                ''
            }
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.Cdn/profiles/profile" -Type 'Microsoft.Cdn/profiles'
            Should -Invoke Invoke-AvmBicepCleanupCli -Exactly 1 -ParameterFilter { $ArgumentList -contains 'delete' }
        }
    }

    It 'does not mistake an APIM deletion failure for success' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepCleanupCli {
                param($ArgumentList)
                if ($ArgumentList -contains 'show') { return '{"location":"eastus"}' }
                [pscustomobject]@{ ExitCode = 1; StdErr = 'Permission denied'; StdOut = '' }
            }
            { Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.ApiManagement/service/apim" `
                    -Type 'Microsoft.ApiManagement/service' } |
                Should -Throw -ExpectedMessage '*Permission denied*'
            Should -Invoke Invoke-AvmBicepCleanupCli -Exactly 0 -ParameterFilter { $ArgumentList -contains 'purge' }
        }
    }

    It 'removes only the exact role assignment, including at tenant scope' {
        InModuleScope Avm.Authoring {
            $script:assignment = '/providers/Microsoft.Authorization/roleAssignments/owned'
            Mock Get-AzRoleAssignment {
                @(
                    [pscustomobject]@{ RoleAssignmentId = $script:assignment }
                    [pscustomobject]@{ RoleAssignmentId = '/providers/Microsoft.Authorization/roleAssignments/foreign' }
                )
            }
            Mock Remove-AzRoleAssignment {}
            Remove-AvmBicepResource -ResourceId $script:assignment -Type 'Microsoft.Authorization/roleAssignments'
            Should -Invoke Get-AzRoleAssignment -Exactly 1 -ParameterFilter { $Scope -eq '/' }
            Should -Invoke Remove-AzRoleAssignment -Exactly 1 -ParameterFilter {
                $InputObject.RoleAssignmentId -eq $script:assignment
            }
        }
    }

    It 'removes managed HSM keys through the data-plane endpoint' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.KeyVault/managedHSMs/hsm/keys/key" `
                -Type 'Microsoft.KeyVault/managedHSMs/keys'
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter {
                $Method -eq 'DELETE' -and $Uri -eq 'https://hsm.managedhsm.azure.net/keys/key?api-version=2025-05-01'
            }
        }
    }

    It 'waits for replication provisioning and disabling before removing the workspace' {
        InModuleScope Avm.Authoring {
            $script:replicationEnabled = $true
            Mock Invoke-AzRestMethod {
                param($Method)
                if ($Method -eq 'PUT') { $script:replicationEnabled = $false }
                [pscustomobject]@{
                    StatusCode = 200
                    Content = @{
                        location = 'eastus'
                        properties = @{
                            replication = @{
                                enabled = $script:replicationEnabled
                                createdDate = [datetime]::UtcNow.AddHours(-2).ToString('o')
                                provisioningState = 'Succeeded'
                            }
                        }
                    } | ConvertTo-Json -Depth 6
                }
            }
            Mock Remove-AzOperationalInsightsWorkspace {}
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.OperationalInsights/workspaces/workspace" `
                -Type 'Microsoft.OperationalInsights/workspaces'
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter {
                $Method -eq 'PUT' -and (($Payload | ConvertFrom-Json).properties.replication.enabled -eq $false)
            }
            Should -Invoke Remove-AzOperationalInsightsWorkspace -Exactly 1
        }
    }

    It 'fails rather than deleting a workspace whose replication never settles' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{
                    StatusCode = 200
                    Content = @{
                        location = 'eastus'
                        properties = @{
                            replication = @{
                                enabled = $true
                                createdDate = [datetime]::UtcNow.AddHours(-2).ToString('o')
                                provisioningState = 'Updating'
                            }
                        }
                    } | ConvertTo-Json -Depth 6
                }
            }
            Mock Remove-AzOperationalInsightsWorkspace {}
            { Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.OperationalInsights/workspaces/workspace" `
                    -Type 'Microsoft.OperationalInsights/workspaces' } |
                Should -Throw -ExpectedMessage '*did not finish provisioning*'
            Should -Invoke Remove-AzOperationalInsightsWorkspace -Exactly 0
        }
    }

    It 'retries a locked APIM service then waits for soft deletion and purges it' {
        InModuleScope Avm.Authoring {
            $script:deleteCount = 0
            Mock Invoke-AvmBicepCleanupCli {
                param($ArgumentList)
                if ($ArgumentList -contains 'delete') {
                    $script:deleteCount++
                    if ($script:deleteCount -eq 1) {
                        return [pscustomobject]@{ ExitCode = 1; StdErr = 'ServiceLocked'; StdOut = '' }
                    }
                    return [pscustomobject]@{ ExitCode = 0; StdErr = ''; StdOut = '' }
                }
                if ($ArgumentList -contains 'show') {
                    if ($ArgumentList -contains 'deletedservice' -or $script:deleteCount -eq 0) {
                        return '{"location":"eastus"}'
                    }
                    return $null
                }
                ''
            }
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.ApiManagement/service/apim" `
                -Type 'Microsoft.ApiManagement/service'
            Should -Invoke Invoke-AvmBicepCleanupCli -Exactly 2 -ParameterFilter { $ArgumentList -contains 'delete' }
            Should -Invoke Invoke-AvmBicepCleanupCli -Exactly 1 -ParameterFilter { $ArgumentList -contains 'purge' }
            Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 60 }
        }
    }

    It 'does not purge an already deleted APIM service belonging to another group' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepCleanupCli { $null }
            Mock Get-AvmBicepCleanupRestCollection {
                @{ name = 'apim'; location = 'eastus'; properties = @{ serviceId = '/foreign-group/providers/Microsoft.ApiManagement/service/apim' } }
            }
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.ApiManagement/service/apim" `
                -Type 'Microsoft.ApiManagement/service'
            Should -Invoke Invoke-AvmBicepCleanupCli -Exactly 0 -ParameterFilter { $ArgumentList -contains 'purge' }
        }
    }

    It 'performs no native mutation or wait when removal is declined' {
        InModuleScope Avm.Authoring {
            Mock Get-AzRoleEligibilityScheduleRequest {}
            Mock New-AzRoleEligibilityScheduleRequest {}
            Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/request" `
                -Type 'Microsoft.Authorization/roleEligibilityScheduleRequests' -WhatIf
            Should -Invoke Remove-AvmBicepResourceLock -Exactly 0
            Should -Invoke Get-AzRoleEligibilityScheduleRequest -Exactly 0
            Should -Invoke New-AzRoleEligibilityScheduleRequest -Exactly 0
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'checks ExpressRoute deletion instead of ignoring lookup errors' {
        InModuleScope Avm.Authoring {
            Mock Remove-AzExpressRouteGateway {}
            Mock Invoke-AvmBicepCleanupLookup { throw 'Gateway lookup denied' }
            { Remove-AvmBicepResource -ResourceId "$script:cleanupGroup/providers/Microsoft.Network/expressRouteGateways/gateway" `
                    -Type 'Microsoft.Network/expressRouteGateways' } |
                Should -Throw -ExpectedMessage '*Gateway lookup denied*'
        }
    }
}

Describe 'Bicep workflow cleanup post-removal' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:cleanupGroup = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'
            Mock Write-AvmLog {}
        }
    }



    It 'fails after post-removal retries rather than warning and succeeding' {
        InModuleScope Avm.Authoring {
            Mock Get-AvmBicepCleanupRestCollection { throw 'Purge lookup denied' }
            { Remove-AvmBicepResourceRemainder -ResourceId "$script:cleanupGroup/providers/Microsoft.AppConfiguration/configurationStores/store" `
                    -Type 'Microsoft.AppConfiguration/configurationStores' } |
                Should -Throw -ExpectedMessage '*Purge lookup denied*'
            Should -Invoke Get-AvmBicepCleanupRestCollection -Exactly 3
        }
    }

    It 'restores the original backup-vault setting even if removing protection fails' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepCleanupLookup {
                param($Command)
                if ($Command -eq 'Get-AzRecoveryServicesVaultProperty') {
                    return [pscustomobject]@{ SoftDeleteFeatureState = 'Enabled' }
                }
                [pscustomobject]@{ Name = 'item'; DeleteState = 'NotDeleted' }
            }
            Mock Set-AzRecoveryServicesVaultProperty {}
            Mock Disable-AzRecoveryServicesBackupProtection { throw 'Protection removal denied' }
            { Remove-AvmBicepResourceRemainder `
                    -ResourceId "$script:cleanupGroup/providers/Microsoft.RecoveryServices/vaults/vault/backupFabrics/Azure/protectionContainers/container/protectedItems/item" `
                    -Type 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems' -PostRemovalRetryLimit 1 } |
                Should -Throw -ExpectedMessage '*Protection removal denied*'
            Should -Invoke Set-AzRecoveryServicesVaultProperty -Exactly 1 -ParameterFilter { $SoftDeleteFeatureState -eq 'Disable' }
            Should -Invoke Set-AzRecoveryServicesVaultProperty -Exactly 1 -ParameterFilter { $SoftDeleteFeatureState -eq 'Enable' }
        }
    }

    It 'does not purge a protected vault or swallow an authorization error' {
        InModuleScope Avm.Authoring {
            $script:vault = "$script:cleanupGroup/providers/Microsoft.KeyVault/vaults/vault"
            Mock Get-AzKeyVault {
                [pscustomobject]@{ ResourceId = $script:vault; Id = $script:vault; EnablePurgeProtection = $true; Location = 'eastus' }
            }
            Mock Remove-AzKeyVault {}
            Remove-AvmBicepResourceRemainder -ResourceId $script:vault -Type 'Microsoft.KeyVault/vaults'
            Should -Invoke Remove-AzKeyVault -Exactly 0
            Mock Get-AzKeyVault {
                [pscustomobject]@{ ResourceId = $script:vault; Id = $script:vault; EnablePurgeProtection = $false; Location = 'eastus' }
            }
            Mock Remove-AzKeyVault { throw 'DeletedVaultPurge authorization denied' }
            { Remove-AvmBicepResourceRemainder -ResourceId $script:vault -Type 'Microsoft.KeyVault/vaults' -PostRemovalRetryLimit 1 } |
                Should -Throw -ExpectedMessage '*authorization denied*'
        }
    }

    It 'restores the original vault setting after a failed restoration and retry' {
        InModuleScope Avm.Authoring {
            $script:softDelete = 'Enabled'
            $script:restoreAttempt = 0
            Mock Invoke-AvmBicepCleanupLookup {
                param($Command)
                if ($Command -eq 'Get-AzRecoveryServicesVaultProperty') {
                    return [pscustomobject]@{ SoftDeleteFeatureState = $script:softDelete }
                }
                $null
            }
            Mock Set-AzRecoveryServicesVaultProperty {
                param($SoftDeleteFeatureState)
                if ($SoftDeleteFeatureState -eq 'Enable') {
                    $script:restoreAttempt++
                    if ($script:restoreAttempt -eq 1) { throw 'Temporary restoration failure' }
                }
                $script:softDelete = $SoftDeleteFeatureState + 'd'
            }
            Remove-AvmBicepResourceRemainder `
                -ResourceId "$script:cleanupGroup/providers/Microsoft.RecoveryServices/vaults/vault/backupFabrics/Azure/protectionContainers/container/protectedItems/item" `
                -Type 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems'
            $script:softDelete | Should -BeExactly 'Enabled'
            Should -Invoke Set-AzRecoveryServicesVaultProperty -Exactly 2 -ParameterFilter { $SoftDeleteFeatureState -eq 'Enable' }
        }
    }

    It 'purges only the matching App Configuration store' {
        InModuleScope Avm.Authoring {
            $script:store = "$script:cleanupGroup/providers/Microsoft.AppConfiguration/configurationStores/store"
            Mock Get-AvmBicepCleanupRestCollection {
                @(
                    @{ properties = @{ configurationStoreId = $script:store; location = 'eastus' } }
                    @{ properties = @{ configurationStoreId = '/foreign/store'; location = 'westus' } }
                )
            }
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 202; Content = '{}' } }
            Remove-AvmBicepResourceRemainder -ResourceId $script:store -Type 'Microsoft.AppConfiguration/configurationStores'
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter {
                $Method -eq 'POST' -and $Path -like '*/locations/eastus/deletedConfigurationStores/store/purge?*'
            }
        }
    }

    It 'does not suppress an APIM purge response failure' {
        InModuleScope Avm.Authoring {
            $script:service = "$script:cleanupGroup/providers/Microsoft.ApiManagement/service/apim"
            Mock Get-AvmBicepCleanupRestCollection {
                @{ location = 'eastus'; properties = @{ serviceId = $script:service } }
            }
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 403; Content = '{}' } }
            { Remove-AvmBicepResourceRemainder -ResourceId $script:service -Type 'Microsoft.ApiManagement/service' -PostRemovalRetryLimit 1 } |
                Should -Throw -ExpectedMessage '*purge failed with HTTP 403*'
        }
    }

    It 'matches a Cognitive Services account by group as well as name' {
        InModuleScope Avm.Authoring {
            Mock Get-AzCognitiveServicesAccount {
                @(
                    [pscustomobject]@{ AccountName = 'account'; ResourceGroupName = 'foreign'; Location = 'westus'; Id = '/foreign' }
                    [pscustomobject]@{ AccountName = 'account'; ResourceGroupName = 'test'; Location = 'eastus'; Id = '/owned' }
                )
            }
            Mock Remove-AzCognitiveServicesAccount {}
            Remove-AvmBicepResourceRemainder -ResourceId "$script:cleanupGroup/providers/Microsoft.CognitiveServices/accounts/account" `
                -Type 'Microsoft.CognitiveServices/accounts'
            Should -Invoke Remove-AzCognitiveServicesAccount -Exactly 1 -ParameterFilter {
                $ResourceGroupName -eq 'test' -and $Location -eq 'eastus'
            }
        }
    }

    It 'uses the recorded Databricks managed group rather than assuming a naming convention' {
        InModuleScope Avm.Authoring {
            $script:workspace = "$script:cleanupGroup/providers/Microsoft.Databricks/workspaces/workspace"
            Mock Invoke-AvmBicepCleanupLookup { [pscustomobject]@{ ManagedBy = $script:workspace } }
            Mock Remove-AzResourceGroup {}
            Remove-AvmBicepResourceRemainder -ResourceId $script:workspace -Type 'Microsoft.Databricks/workspaces' `
                -ManagedResourceGroupIds @('/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/custom-managed')
            Should -Invoke Remove-AzResourceGroup -Exactly 1 -ParameterFilter { $Name -eq 'custom-managed' }
        }
    }

    It 'does not retry a cancelled post-removal operation' {
        InModuleScope Avm.Authoring {
            Mock Get-AvmBicepCleanupRestCollection { throw [System.OperationCanceledException]::new('Cancelled') }
            { Remove-AvmBicepResourceRemainder -ResourceId "$script:cleanupGroup/providers/Microsoft.AppConfiguration/configurationStores/store" `
                    -Type 'Microsoft.AppConfiguration/configurationStores' } |
                Should -Throw -ExpectedMessage '*Cancelled*'
            Should -Invoke Get-AvmBicepCleanupRestCollection -Exactly 1
        }
    }

    It 'does not delete a coincidentally named Databricks group belonging to another workspace' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepCleanupLookup { [pscustomobject]@{ ManagedBy = '/foreign-workspace' } }
            Mock Remove-AzResourceGroup {}
            { Remove-AvmBicepResourceRemainder -ResourceId "$script:cleanupGroup/providers/Microsoft.Databricks/workspaces/workspace" `
                    -Type 'Microsoft.Databricks/workspaces' -PostRemovalRetryLimit 1 } |
                Should -Throw -ExpectedMessage '*not managed by*'
            Should -Invoke Remove-AzResourceGroup -Exactly 0
        }
    }
}

Describe 'Bicep workflow cleanup deployment discovery' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:root = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/root'
            $script:group = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
            Mock Set-AzContext { throw 'Discovery must use the full deployment ID, not change the active context.' }
        }


    }

    It 'follows exact child group, subscription, management-group and tenant IDs without deleting Read targets' {
        InModuleScope Avm.Authoring {
            $childGroup = "$script:group/providers/Microsoft.Resources/deployments/child"
            $childSubscription = '/subscriptions/00000000-0000-0000-0000-000000000003/providers/Microsoft.Resources/deployments/child'
            $childManagementGroup = '/providers/Microsoft.Management/managementGroups/actual-child/providers/Microsoft.Resources/deployments/child'
            $childTenant = '/providers/Microsoft.Resources/deployments/child'
            $operation = {
                param($Id, $Kind = 'Create')
                @{ properties = @{ provisioningOperation = $Kind; targetResource = @{ id = $Id } } }
            }
            $script:pages = @{
                ($script:root + '/operations?api-version=2021-04-01')          = @{
                    value = @(
                        & $operation $script:group
                        & $operation $childGroup
                        & $operation $childSubscription
                        & $operation $childManagementGroup
                        & $operation $childTenant
                        & $operation "$script:group/providers/Microsoft.Storage/storageAccounts/borrowed" 'Read'
                    )
                }
                ($childGroup + '/operations?api-version=2021-04-01')           = @{
                    value = @(
                        & $operation "$script:group/providers/Microsoft.Storage/storageAccounts/created"
                        & $operation $script:root
                    )
                }
                ($childSubscription + '/operations?api-version=2021-04-01')    = @{ value = @() }
                ($childManagementGroup + '/operations?api-version=2021-04-01') = @{
                    value = @(& $operation '/providers/Microsoft.Management/managementGroups/actual-child/providers/Microsoft.Authorization/policyDefinitions/created')
                }
                ($childTenant + '/operations?api-version=2021-04-01')          = @{
                    value = @(& $operation '/providers/Microsoft.Management/managementGroups/new-group')
                }
            }
            Mock Invoke-AzRestMethod {
                param($Path)
                if (-not $script:pages.ContainsKey($Path)) { throw "Unexpected path $Path" }
                [pscustomobject]@{ StatusCode = 200; Content = $script:pages[$Path] | ConvertTo-Json -Depth 10 }
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root)
            $result.Issues.Count | Should -Be 0
            $result.ResourceIds.Count | Should -Be 4
            $result.ResourceIds | Should -Contain "$script:group/providers/Microsoft.Storage/storageAccounts/created"
            $result.ResourceIds | Should -Not -Contain "$script:group/providers/Microsoft.Storage/storageAccounts/borrowed"
            $result.Deployments.Count | Should -Be 5
            Should -Invoke Invoke-AzRestMethod -Exactly 5
            Should -Invoke Set-AzContext -Exactly 0
        }
    }

    It 'resolves an empty operation array without a boolean sentinel' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root)
            $result.ResourceIds.Count | Should -Be 0
            $result.Issues.Count | Should -Be 0
            $result.Deployments[0].Status | Should -BeExactly 'Resolved'
            Should -Invoke Invoke-AzRestMethod -Exactly 1
        }
    }

    It 'retries only confirmed missing top-level deployments' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}' }
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) -SearchRetryLimit 3 -SearchRetryInterval 0
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].Code | Should -BeExactly 'DeploymentNotFound'
            Should -Invoke Invoke-AzRestMethod -Exactly 3
            Should -Invoke Start-Sleep -Exactly 2
        }
    }

    It 'checks a preflight rejection once before deciding no deployment was created' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}' }
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) `
                -PreflightRejectedDeploymentIds @($script:root)
            $result.Issues.Count | Should -Be 0
            $result.Deployments[0].Status | Should -BeExactly 'RejectedWithoutRecord'
            Should -Invoke Invoke-AzRestMethod -Exactly 1
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'still discovers an existing preflight-rejected deployment record' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{
                    StatusCode = 200
                    Content    = @{ value = @(@{
                                properties = @{ provisioningOperation = 'Create'; targetResource = @{ id = $script:group } }
                            })
                    } | ConvertTo-Json -Depth 10
                }
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) `
                -PreflightRejectedDeploymentIds @($script:root)
            $result.ResourceIds | Should -Contain $script:group
            $result.Deployments[0].Status | Should -BeExactly 'Resolved'
        }
    }

    It 'retains known targets after a later page times out and still reads other attempts' {
        InModuleScope Avm.Authoring {
            $other = $script:root + '-other'
            Mock Invoke-AzRestMethod {
                param($Path)
                if ($Path -like '*page=2') { throw [System.TimeoutException]::new('Timed out') }
                if ($Path -like '*-other/operations?*') {
                    return [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' }
                }
                [pscustomobject]@{
                    StatusCode = 200
                    Content    = @{
                        value    = @(@{
                                properties = @{ provisioningOperation = 'Create'; targetResource = @{ id = $script:group } }
                            })
                        nextLink = "$script:root/operations?page=2"
                    } | ConvertTo-Json -Depth 10
                }
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root, $other)
            $result.ResourceIds | Should -Contain $script:group
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].Message | Should -Match 'Timed out'
            @($result.Deployments | Where-Object { $_.Status -eq 'Resolved' }).Count | Should -Be 1
            Should -Invoke Invoke-AzRestMethod -Exactly 3
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'does not misclassify a later-page disappearance as an unsubmitted preflight rejection' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {
                param($Path)
                if ($Path -like '*page=2') {
                    return [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}' }
                }
                [pscustomobject]@{
                    StatusCode = 200
                    Content    = @{
                        value    = @(@{ properties = @{ provisioningOperation = 'Create'; targetResource = @{ id = $script:group } } })
                        nextLink = "$script:root/operations?page=2"
                    } | ConvertTo-Json -Depth 10
                }
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) `
                -PreflightRejectedDeploymentIds @($script:root)
            $result.ResourceIds | Should -Contain $script:group
            $result.Issues.Count | Should -Be 1
            $result.Deployments[0].Status | Should -BeExactly 'Failed'
            Should -Invoke Invoke-AzRestMethod -Exactly 2
        }
    }

    It 'does not retry or suppress an authorization-shaped 404' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"AuthorizationFailed"}}' }
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) `
                -PreflightRejectedDeploymentIds @($script:root)
            $result.Issues.Count | Should -Be 1
            $result.Deployments[0].Status | Should -BeExactly 'Failed'
            Should -Invoke Invoke-AzRestMethod -Exactly 1
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'propagates cancellation instead of returning cleanup candidates' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod { throw [System.OperationCanceledException]::new('Cancelled by operator') }
            { Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) } |
                Should -Throw -ExpectedMessage '*Cancelled by operator*'
            Should -Invoke Invoke-AzRestMethod -Exactly 1
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'rejects preflight metadata for a different attempt before any lookup' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod {}
            { Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) `
                    -PreflightRejectedDeploymentIds @($script:root + '-other') } |
                Should -Throw -ExpectedMessage '*outside the attempted deployments*'
            Should -Invoke Invoke-AzRestMethod -Exactly 0
        }
    }
}

Describe 'Bicep workflow cleanup CLI boundary' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            Mock Get-Command { [pscustomobject]@{ Source = 'fake-az' } }
            Mock Get-AzContext {
                [pscustomobject]@{
                    Subscription = @{ Id = '00000000-0000-0000-0000-000000000003' }
                    Tenant = @{ Id = '00000000-0000-0000-0000-000000000002' }
                }
            }
            Mock Assert-AvmBicepAzureIdentity {}
        }
    }

    It 'supplies the active native subscription as a separate CLI argument' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = '{"name":"test"}'; StdErr = '' } }
            Invoke-AvmBicepCleanupCli -ArgumentList @('apim', 'show', '--name', 'test') | Should -Be '{"name":"test"}'
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq 'fake-az' -and $ArgumentList[-4] -eq '--subscription' -and
                $ArgumentList[-3] -eq '00000000-0000-0000-0000-000000000003'
            }
            Should -Invoke Assert-AvmBicepAzureIdentity -Exactly 1 -ParameterFilter {
                $SubscriptionId -eq '00000000-0000-0000-0000-000000000003' -and
                $TenantId -eq '00000000-0000-0000-0000-000000000002'
            }
        }
    }

    It 'accepts only the specific not-found response and not a generic CLI failure' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (ResourceNotFound) Gone' }
            }
            Invoke-AvmBicepCleanupCli -ArgumentList @('apim', 'show') -AllowNotFound | Should -BeNullOrEmpty
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (AuthorizationFailed) ResourceNotFound does not apply' }
            }
            { Invoke-AvmBicepCleanupCli -ArgumentList @('apim', 'show') -AllowNotFound } |
                Should -Throw -ExpectedMessage '*AuthorizationFailed*'
        }
    }

    It 'rejects empty or incorrectly shaped successful lookups: <Body>' -ForEach @(
        @{ Body = '' }
        @{ Body = 'null' }
        @{ Body = '[]' }
        @{ Body = 'not JSON' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Body = $Body } {
            param($Body)
            $script:cliBody = $Body
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $script:cliBody; StdErr = '' } }
            { Invoke-AvmBicepCleanupCli -ArgumentList @('apim', 'show') -AllowNotFound } | Should -Throw
        }
    }

    It 'does not run a deletion in WhatIf mode' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmProcess {}
            Invoke-AvmBicepCleanupCli -ArgumentList @('apim', 'delete', '--name', 'test', '--yes') -WhatIf
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }
}
