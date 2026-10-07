#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        foreach ($name in @('Get-AzResourceProvider', 'Get-AzLocation')) {
            Set-Item -Path "Function:script:$name" -Value {
                [CmdletBinding()]
                param($ProviderNamespace)
                throw "Unexpected Azure call: $($MyInvocation.MyCommand.Name)"
            }
        }
    }
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep registry metadata timeout retries' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:metadataAttempts = 0
            Mock Wait-AvmRetryDelay {}
        }
    }

    It 'buffers failed reads and returns only the completed attempt' {
        InModuleScope Avm.Authoring {
            $result = @(Invoke-AvmBicepMetadataRead -Activity 'fixture metadata' -Read {
                    $script:metadataAttempts++
                    if ($script:metadataAttempts -eq 1) {
                        'partial metadata'
                        throw [TimeoutException]::new('Request timed out.')
                    }
                    'complete metadata'
                })
            $result | Should -Be @('complete metadata')
            $script:metadataAttempts | Should -Be 2
            Should -Invoke Wait-AvmRetryDelay -Exactly 1
        }
    }

    It 'limits typed request timeouts to three reads: <Mode>' -ForEach @(
        @{ Mode = 'terminating' }, @{ Mode = 'non-terminating' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mode = $Mode } {
            param($Mode)
            {
                Invoke-AvmBicepMetadataRead -Activity 'fixture metadata' -Read {
                    $script:metadataAttempts++
                    if ($Mode -eq 'non-terminating') { Write-Error -Exception ([TimeoutException]::new('Request timed out.')) }
                    else { throw [TimeoutException]::new('Request timed out.') }
                }
            } | Should -Throw '*timed out*'
            $script:metadataAttempts | Should -Be 3
            Should -Invoke Wait-AvmRetryDelay -Exactly 2
        }
    }

    It 'does not retry <Failure> even alongside timeout evidence' -ForEach @(
        @{ Failure = 'message only' }, @{ Failure = 'transport' }, @{ Failure = 'cancellation' }
        @{ Failure = 'permission' }, @{ Failure = 'authentication' }, @{ Failure = 'security' }
        @{ Failure = 'HTTP 401' }, @{ Failure = 'HTTP 403' }, @{ Failure = 'category' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Failure = $Failure } {
            param($Failure)
            $timeout = [TimeoutException]::new('Request timed out.')
            $exception = switch ($Failure) {
                'message only' { [InvalidOperationException]::new('Request timed out.') }
                'transport' { [System.Net.Http.HttpRequestException]::new('Connection reset.') }
                'cancellation' { [AggregateException]::new([Exception[]]@($timeout, [OperationCanceledException]::new('Cancelled.'))) }
                'permission' { [AggregateException]::new([Exception[]]@($timeout, [UnauthorizedAccessException]::new('Denied.'))) }
                'authentication' { [System.Security.Authentication.AuthenticationException]::new('Denied.', $timeout) }
                'security' { [System.Security.SecurityException]::new('Denied.', $timeout) }
                'HTTP 401' { [System.Net.Http.HttpRequestException]::new('Denied.', $timeout, [System.Net.HttpStatusCode]::Unauthorized) }
                'HTTP 403' { [System.Net.Http.HttpRequestException]::new('Denied.', $timeout, [System.Net.HttpStatusCode]::Forbidden) }
                default { $timeout }
            }
            $category = if ($Failure -eq 'category') { [System.Management.Automation.ErrorCategory]::PermissionDenied }
            else { [System.Management.Automation.ErrorCategory]::InvalidResult }
            $script:metadataError = [System.Management.Automation.ErrorRecord]::new($exception, 'MetadataFixture', $category, $null)
            {
                Invoke-AvmBicepMetadataRead -Activity 'fixture metadata' -Read {
                    $script:metadataAttempts++
                    throw $script:metadataError
                }
            } | Should -Throw
            $script:metadataAttempts | Should -Be 1
            Should -Invoke Wait-AvmRetryDelay -Exactly 0
        }
    }

    It 'retries only the failed provider/location read: <FailedRead>' -ForEach @(
        @{ FailedRead = 'provider' }, @{ FailedRead = 'location' }, @{ FailedRead = 'both' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ FailedRead = $FailedRead } {
            param($FailedRead)
            $script:providerReads = 0
            $script:locationReads = 0
            Mock Get-AzResourceProvider {
                $script:providerReads++
                if ($script:providerReads -eq 1 -and $FailedRead -in @('provider', 'both')) {
                    throw [TimeoutException]::new('Provider read timed out.')
                }
                @{ ResourceTypes = @(@{ ResourceTypeName = 'storageAccounts'; Locations = @('East US') }) }
            }
            Mock Get-AzLocation {
                $script:locationReads++
                if ($script:locationReads -eq 1 -and $FailedRead -in @('location', 'both')) {
                    throw [TimeoutException]::new('Location read timed out.')
                }
                @{ Location = 'eastus'; DisplayName = 'East US'; RegionCategory = 'Recommended'; PairedRegion = 'westus' }
            }
            (Get-AvmBicepResourceLocation -ResourceType 'Microsoft.Storage/storageAccounts' -MetadataLocation 'westus').Location |
                Should -BeExactly 'eastus'
            $script:providerReads | Should -Be $(if ($FailedRead -in @('provider', 'both')) { 2 } else { 1 })
            $script:locationReads | Should -Be $(if ($FailedRead -in @('location', 'both')) { 2 } else { 1 })
        }
    }
}

Describe 'Bicep registry structured retry evidence' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:subscription = '11111111-1111-1111-1111-111111111111'
            $script:resourcePrefix = "/subscriptions/$script:subscription/resourceGroups/retry-fixture/providers/"
            $script:aci = @{
                code = 'ResourceDeploymentFailure'; target = $script:resourcePrefix + 'Microsoft.ContainerInstance/containerGroups/test'
                details = @(@{ message = "The requested resource is not available in the location 'swedencentral' at this moment. Please retry with a different resource request or in another location. Resource requested: '4' CPU '16' GB memory 'Linux' OS" })
            }
            $script:aks = @{
                code = 'InvalidTemplateDeployment'
                message = "The template deployment 'test-aks' is not valid according to the validation procedure. The following resource provider(s) - 'Microsoft.ContainerService/managedClusters (2025-10-01)' reported preflight validation errors. Tracking id is '22222222-2222-2222-2222-222222222222'. See inner errors for details."
                details = @(@{
                        code = 'AvailabilityZoneNotSupported'
                        message = "Preflight validation check for resource(s) for container service private-cluster in resource group retry-fixture failed. Message: The zone(s) '3' for resource 'systempool' is not supported. The supported zones for location 'swedencentral' are ''. Details: "
                    })
            }
            $cosmosMessage = "Sorry, we are currently experiencing high demand in Norway East region, and cannot fulfill your request at this time Mon, 05 Oct 2026 07:42:40 GMT. To request region access for your subscription, please follow this link https://aka.ms/cosmosdbquota for more details on how to create a region access request.`r`nActivityId: 33333333-3333-3333-3333-333333333333, Microsoft.Azure.Documents.Common/2.14.0"
            $cosmosJson = @{ code = 'ServiceUnavailable'; message = $cosmosMessage } | ConvertTo-Json -Compress
            $script:cosmos = @{
                code = 'ResourceDeploymentFailure'; target = $script:resourcePrefix + 'Microsoft.MachineLearningServices/workspaces/test'
                details = @(@{
                        code = 'BadRequest'
                        message = "Long running operation failed with status 'Failed'. Additional Info:'Database account creation failed. Operation Id: 22222222-2222-2222-2222-222222222222, Error : Message: $cosmosJson, Request URI: /serviceReservation, RequestStats: , SDK: Microsoft.Azure.Documents.Common/2.14.0'"
                    })
            }
        }
    }

    It 'accepts exact captured regional shapes with matching location context: <Shape>' -ForEach @(
        @{ Shape = 'aci'; Location = 'swedencentral' }
        @{ Shape = 'aks'; Location = 'swedencentral' }
        @{ Shape = 'cosmos'; Location = 'norwayeast' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Shape = $Shape; Location = $Location } {
            param($Shape, $Location)
            $node = @{ error = (Get-Variable -Name $Shape -Scope Script -ValueOnly); status = 'Failed' }
            Test-AvmBicepRetryErrorNode -Node $node -SubscriptionId $script:subscription -ResourceLocation $Location | Should -BeTrue
            $failure = [System.Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Validation failed.'), 'NativeFailure',
                [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
            $failure.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(($node | ConvertTo-Json -Depth 20))
            Test-AvmBicepRegionalValidationError -ErrorRecord $failure -SubscriptionId $script:subscription -ResourceLocation $Location |
                Should -BeTrue
            Test-AvmBicepRegionalValidationError -ErrorRecord $failure -SubscriptionId $script:subscription -ResourceLocation 'eastus' |
                Should -BeFalse
            Test-AvmBicepRetryErrorNode -Node $node -RetryKind Transient -SubscriptionId $script:subscription -ResourceLocation $Location |
                Should -BeFalse
        }
    }

    It 'rejects nonstandard or ambiguous ACI evidence: <Mutation>' -ForEach @(
        @{ Mutation = 'missing location' }, @{ Mutation = 'wrong subscription' }, @{ Mutation = 'wrong resource' }
        @{ Mutation = 'query target' }, @{ Mutation = 'zero CPU' }, @{ Mutation = 'excess CPU' }
        @{ Mutation = 'excess memory' }, @{ Mutation = 'Windows' }, @{ Mutation = 'unknown code' }
        @{ Mutation = 'empty code' }, @{ Mutation = 'null code' }, @{ Mutation = 'extra leaf field' }
        @{ Mutation = 'mixed child' }, @{ Mutation = 'array message' }, @{ Mutation = 'unknown ancestor' }
        @{ Mutation = 'shadowed Keys' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mutation = $Mutation } {
            param($Mutation)
            $location = 'swedencentral'
            switch ($Mutation) {
                'missing location' { $location = '' }
                'wrong subscription' { $script:aci.target = $script:aci.target.Replace($script:subscription, '22222222-2222-2222-2222-222222222222') }
                'wrong resource' { $script:aci.target = $script:aci.target.Replace('containerGroups', 'notContainers') }
                'query target' { $script:aci.target += '?x=y' }
                'zero CPU' { $script:aci.details[0].message = $script:aci.details[0].message.Replace("'4' CPU", "'0' CPU") }
                'excess CPU' { $script:aci.details[0].message = $script:aci.details[0].message.Replace("'4' CPU", "'4.1' CPU") }
                'excess memory' { $script:aci.details[0].message = $script:aci.details[0].message.Replace("'16' GB", "'17' GB") }
                'Windows' { $script:aci.details[0].message = $script:aci.details[0].message.Replace("'Linux'", "'Windows'") }
                'unknown code' { $script:aci.details[0].code = 'Unknown' }
                'empty code' { $script:aci.details[0].code = '' }
                'null code' { $script:aci.details[0].code = $null }
                'extra leaf field' { $script:aci.details[0]['Count'] = 1 }
                'mixed child' { $script:aci.details += @{ code = 'AuthorizationFailed'; message = 'Denied.' } }
                'array message' { $script:aci.details[0].message = @($script:aci.details[0].message) }
                'unknown ancestor' { $script:aci['unexpected'] = 'information' }
                'shadowed Keys' { $script:aci['Keys'] = @('code', 'target', 'details') }
            }
            Test-AvmBicepRetryErrorNode -Node $script:aci -SubscriptionId $script:subscription -ResourceLocation $location |
                Should -BeFalse
        }
    }

    It 'rejects broader AKS zone/configuration failures: <Mutation>' -ForEach @(
        @{ Mutation = 'nonempty supported zones' }, @{ Mutation = 'duplicate requested zones' }
        @{ Mutation = 'invalid requested zone' }, @{ Mutation = 'different provider' }, @{ Mutation = 'invalid API date' }
        @{ Mutation = 'invalid tracking ID' }, @{ Mutation = 'extra details' }, @{ Mutation = 'target' }
        @{ Mutation = 'unknown ancestor' }, @{ Mutation = 'missing parent' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mutation = $Mutation } {
            param($Mutation)
            switch ($Mutation) {
                'nonempty supported zones' { $script:aks.details[0].message = $script:aks.details[0].message.Replace("are ''", "are '1,2'") }
                'duplicate requested zones' { $script:aks.details[0].message = $script:aks.details[0].message.Replace("'3' for", "'3,3' for") }
                'invalid requested zone' { $script:aks.details[0].message = $script:aks.details[0].message.Replace("'3' for", "'4' for") }
                'different provider' { $script:aks.message = $script:aks.message.Replace('managedClusters', 'agentPools') }
                'invalid API date' { $script:aks.message = $script:aks.message.Replace('2025-10-01', '2025-99-01') }
                'invalid tracking ID' { $script:aks.message = $script:aks.message.Replace('22222222-2222-2222-2222-222222222222', 'unknown') }
                'extra details' { $script:aks.details[0].details = @() }
                'target' { $script:aks.details[0].target = $script:resourcePrefix + 'Microsoft.ContainerService/managedClusters/test' }
                'unknown ancestor' { $script:aks['unexpected'] = 'information' }
                'missing parent' { $script:aks = $script:aks.details[0] }
            }
            Test-AvmBicepRetryErrorNode -Node $script:aks -ResourceLocation 'swedencentral' | Should -BeFalse
        }
    }

    It 'rejects broader ML/Cosmos errors: <Mutation>' -ForEach @(
        @{ Mutation = 'wrong workspace' }, @{ Mutation = 'unknown code' }, @{ Mutation = 'bad timestamp' }
        @{ Mutation = 'bad SDK' }, @{ Mutation = 'wrong request URI' }, @{ Mutation = 'duplicate JSON code' }
        @{ Mutation = 'extra JSON field' }, @{ Mutation = 'extra details' }, @{ Mutation = 'wrong target' }
        @{ Mutation = 'unknown ancestor' }, @{ Mutation = 'missing parent' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mutation = $Mutation } {
            param($Mutation)
            switch ($Mutation) {
                'wrong workspace' { $script:cosmos.target = $script:cosmos.target.Replace('workspaces', 'computes') }
                'unknown code' { $script:cosmos.details[0].message = $script:cosmos.details[0].message.Replace('ServiceUnavailable', 'QuotaExceeded') }
                'bad timestamp' { $script:cosmos.details[0].message = $script:cosmos.details[0].message.Replace('05 Oct', '99 Oct') }
                'bad SDK' { $script:cosmos.details[0].message = $script:cosmos.details[0].message.Replace('2.14.0', 'unclassified') }
                'wrong request URI' { $script:cosmos.details[0].message = $script:cosmos.details[0].message.Replace('/serviceReservation', '/databases') }
                'duplicate JSON code' { $script:cosmos.details[0].message = $script:cosmos.details[0].message.Replace('"code":', '"code":"Other","code":') }
                'extra JSON field' { $script:cosmos.details[0].message = $script:cosmos.details[0].message.Replace('"code":', '"Count":2,"code":') }
                'extra details' { $script:cosmos.details[0].details = @() }
                'wrong target' { $script:cosmos.details[0].target = $script:cosmos.target + '-other' }
                'unknown ancestor' { $script:cosmos['unexpected'] = 'information' }
                'missing parent' { $script:cosmos = $script:cosmos.details[0] }
            }
            Test-AvmBicepRetryErrorNode -Node $script:cosmos -ResourceLocation 'norwayeast' | Should -BeFalse
        }
    }

    It 'rejects duplicate raw JSON evidence before regional classification: <Property>' -ForEach @(
        @{ Property = 'code' }, @{ Property = 'Code' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Property = $Property } {
            param($Property)
            $json = @{ error = $script:aks } | ConvertTo-Json -Depth 20 -Compress
            $json = $json.Replace('"code":"AvailabilityZoneNotSupported"', "`"$Property`":`"Unknown`",`"code`":`"AvailabilityZoneNotSupported`"")
            $failure = [System.Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Validation failed.'), 'NativeFailure',
                [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
            $failure.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($json)
            Test-AvmBicepRegionalValidationError -ErrorRecord $failure -ResourceLocation 'swedencentral' | Should -BeFalse
        }
    }

    It 'preserves raw error-array compatibility and rejects mixed or duplicate evidence: <Shape>' -ForEach @(
        @{ Shape = 'singleton'; Json = '[{"code":"AllocationFailed","message":"Insufficient region capacity."}]'; Qualifies = $true; Items = 1 }
        @{ Shape = 'multiple'; Json = '[{"code":"AllocationFailed","message":"Insufficient region capacity."},{"code":"SkuNotAvailable","message":"Not available in the region."}]'; Qualifies = $true; Items = 2 }
        @{ Shape = 'empty'; Json = '[]'; Qualifies = $false; Items = 0 }
        @{ Shape = 'mixed'; Json = '[{"code":"AllocationFailed","message":"Insufficient region capacity."},{"code":"AuthorizationFailed","message":"Denied."}]'; Qualifies = $false; Items = 2 }
        @{ Shape = 'duplicate'; Json = '[{"code":"AuthorizationFailed","Code":"AllocationFailed","message":"Insufficient region capacity."}]'; Qualifies = $false; Items = -1 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Json = $Json; Qualifies = $Qualifies; Items = $Items } {
            param($Json, $Qualifies, $Items)
            $failure = [System.Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Validation failed.'), 'NativeFailure',
                [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
            $failure.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Json)
            $actual = Get-AvmBicepErrorResponse -ErrorRecord $failure
            if ($Items -ge 0) {
                ($actual -is [array]) | Should -BeTrue
                $actual.Count | Should -Be $Items
            }
            else { $actual | Should -BeNullOrEmpty }
            Test-AvmBicepRegionalValidationError -ErrorRecord $failure | Should -Be $Qualifies
            { ConvertFrom-AvmMetadataJson -Json $Json } | Should -Throw
        }
    }

    It 'classifies resource-specific internal errors only for same-region cleanup: <ResourceType>' -ForEach @(
        @{ ResourceType = 'Microsoft.Network/applicationGateways' }
        @{ ResourceType = 'Microsoft.Network/privateEndpoints' }
        @{ ResourceType = 'Microsoft.DBforPostgreSQL/flexibleServers' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ ResourceType = $ResourceType } {
            param($ResourceType)
            $node = @{
                code = 'ResourceDeploymentFailure'; target = $script:resourcePrefix + $ResourceType + '/test'
                details = @(@{ code = 'InternalServerError'; message = 'An internal error occurred.' })
            }
            Test-AvmBicepRetryErrorNode -Node $node -RetryKind Transient -SubscriptionId $script:subscription | Should -BeTrue
            Test-AvmBicepRetryErrorNode -Node $node -SubscriptionId $script:subscription | Should -BeFalse
            $node.details += $script:aci
            Test-AvmBicepRetryErrorNode -Node $node -RetryKind Transient -SubscriptionId $script:subscription | Should -BeFalse
        }
    }

    It 'rejects incomplete or unowned transient evidence: <Mutation>' -ForEach @(
        @{ Mutation = 'unsupported type' }, @{ Mutation = 'different subscription' }, @{ Mutation = 'different leaf target' }
        @{ Mutation = 'no resource wrapper' }, @{ Mutation = 'empty message' }, @{ Mutation = 'unknown child' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mutation = $Mutation } {
            param($Mutation)
            $node = @{
                code = 'ResourceDeploymentFailure'; target = $script:resourcePrefix + 'Microsoft.Network/privateEndpoints/test'
                details = @(@{ code = 'InternalServerError'; message = 'An internal error occurred.' })
            }
            switch ($Mutation) {
                'unsupported type' { $node.target = $node.target.Replace('privateEndpoints', 'virtualNetworks') }
                'different subscription' { $node.target = $node.target.Replace($script:subscription, '22222222-2222-2222-2222-222222222222') }
                'different leaf target' { $node.details[0].target = $node.target + '-other' }
                'no resource wrapper' { $node = $node.details[0] }
                'empty message' { $node.details[0].message = '' }
                'unknown child' { $node.details += @{ code = 'AuthorizationFailed'; message = 'Denied.' } }
            }
            Test-AvmBicepRetryErrorNode -Node $node -RetryKind Transient -SubscriptionId $script:subscription | Should -BeFalse
        }
    }
}
