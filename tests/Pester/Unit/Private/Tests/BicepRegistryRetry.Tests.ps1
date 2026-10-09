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
            $result = @(Invoke-AvmBicepRead -Activity 'fixture metadata' -Read {
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
                Invoke-AvmBicepRead -Activity 'fixture metadata' -Read {
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
                Invoke-AvmBicepRead -Activity 'fixture metadata' -Read {
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

    It 'refuses any HTTP status alongside timeout evidence: <Status>' -ForEach @(
            @{ Status = 200 }, @{ Status = 408 }, @{ Status = 429 }, @{ Status = 500 }, @{ Status = 503 }
        ) {
            InModuleScope Avm.Authoring -Parameters @{ Status = $Status } {
                param($Status)
                $script:metadataFault = [Net.Http.HttpRequestException]::new(
                    'HTTP response with a timeout cause.', [TimeoutException]::new(), [Net.HttpStatusCode]$Status)
                {
                    Invoke-AvmBicepRead -Activity 'fixture status read' -Read {
                        $script:metadataAttempts++
                        throw $script:metadataFault
                    }
                } | Should -Throw
                $script:metadataAttempts | Should -Be 1
                Should -Invoke Wait-AvmRetryDelay -Exactly 0
            }
        }

    It 'visits independent RuntimeException error-record causes without hiding <Cause>' -ForEach @(
            @{ Cause = 'cancellation' }, @{ Cause = 'unknown' }, @{ Cause = 'permission' }
        ) {
            InModuleScope Avm.Authoring -Parameters @{ Cause = $Cause } {
                param($Cause)
                $inner = switch ($Cause) {
                    'cancellation' { [OperationCanceledException]::new('Cancelled.') }
                    'permission' { [UnauthorizedAccessException]::new('Denied.') }
                    default { [InvalidOperationException]::new('Unknown.') }
                }
                $category = if ($Cause -eq 'permission') { 'PermissionDenied' } else { 'InvalidResult' }
                $record = [Management.Automation.ErrorRecord]::new($inner, 'IndependentCause', $category, $null)
                $fault = [Management.Automation.RuntimeException]::new('Outer timeout.', [TimeoutException]::new(), $record)
                $outer = [Management.Automation.ErrorRecord]::new($fault, 'OuterCause', 'InvalidResult', $null)
                Test-AvmBicepRetryErrorRecord -ErrorRecord $outer -Kind MetadataTimeout | Should -BeFalse
                if ($Cause -eq 'cancellation') {
                    Get-AvmBicepDeploymentErrorKind -ErrorRecord $outer | Should -Be 'Cancellation'
            }
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
            $script:providerLocation = @{
                code = 'LocationNotAvailableForResourceType'
                message = "The provided location 'norwayeast' is not available for resource type 'Microsoft.DesktopVirtualization/hostpools'. List of available regions for the resource type is 'eastus,westeurope'."
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
        @{ Shape = 'providerLocation'; Location = 'norwayeast' }
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

    It 'accepts null SDK optional members without mutating <Shape> evidence' -ForEach @(
        @{ Shape = 'aks'; Location = 'swedencentral' }
        @{ Shape = 'providerLocation'; Location = 'norwayeast' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Shape = $Shape; Location = $Location } {
            param($Shape, $Location)
            $node = Get-Variable -Name $Shape -Scope Script -ValueOnly | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $node | Add-Member -NotePropertyName Target -NotePropertyValue $null
            $leaf = if ($Shape -eq 'aks') { $node.details[0] } else { $node }
            if ($Shape -eq 'aks') { $leaf | Add-Member -NotePropertyName Target -NotePropertyValue $null }
            $leaf | Add-Member -NotePropertyName Details -NotePropertyValue $null
            $original = ConvertTo-Json -InputObject $node -Depth 20 -Compress
            $list = [Collections.Generic.List[object]]::new()
            $list.Add($node)
            foreach ($source in @($node, $list, @{ status = 'Failed'; error = $node }, $original)) {
                $jsonSource = $source -is [string]
                $failure = [Management.Automation.ErrorRecord]::new(
                    [InvalidOperationException]::new('Safe validation summary.'),
                    $(if ($jsonSource) { 'NativeFailure' } else { 'AvmBicepTemplateValidationFailed' }),
                    [Management.Automation.ErrorCategory]::InvalidResult, $source)
                $failure.ErrorDetails = [Management.Automation.ErrorDetails]::new(
                    $(if ($jsonSource) { $source } else { 'Safe diagnostic text, not classification evidence.' }))
                $detail = $failure.ErrorDetails.Message
                Test-AvmBicepRegionalValidationError -ErrorRecord $failure -ResourceLocation $Location | Should -BeTrue
                [object]::ReferenceEquals($failure.TargetObject, $source) | Should -BeTrue
                $failure.ErrorDetails.Message | Should -BeExactly $detail
                (ConvertTo-Json -InputObject $node -Depth 20 -Compress) | Should -BeExactly $original
            }
        }
    }

    It 'retains narrow preflight field guards for <Field>: <Kind>' -ForEach @(
        @{ Field = 'target'; Kind = 'meaningful'; Value = 'another-resource' }
        @{ Field = 'target'; Kind = 'empty'; Value = '' }
        @{ Field = 'target'; Kind = 'Boolean'; Value = $false }
        @{ Field = 'details'; Kind = 'empty array'; Value = @() }
        @{ Field = 'details'; Kind = 'object'; Value = @{} }
        @{ Field = 'innererror'; Kind = 'null'; Value = $null }
        @{ Field = 'additionalInfo'; Kind = 'null'; Value = $null }
        @{ Field = 'additionalInfo'; Kind = 'empty array'; Value = @() }
        @{ Field = 'additionalInfo'; Kind = 'authorization'; Value = @{ code = 'AuthorizationFailed' } }
        @{ Field = 'unknown'; Kind = 'null'; Value = $null }
        @{ Field = 'message'; Kind = 'null'; Value = $null }
        @{ Field = 'code'; Kind = 'unknown'; Value = 'Unknown' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Field = $Field; Value = $Value } {
            param($Field, $Value)
            foreach ($shape in @('aks', 'providerLocation')) {
                $node = Get-Variable -Name $shape -Scope Script -ValueOnly
                $location = if ($shape -eq 'aks') { 'swedencentral' } else { 'norwayeast' }
                $leaf = if ($shape -eq 'aks') { $node.details[0] } else { $node }
                $leaf[$Field] = $Value
                Test-AvmBicepRetryErrorNode -Node $node -ResourceLocation $location | Should -BeFalse -Because $shape
            }
        }
    }

    It 'matches provider availability to canonical and display-name regions: <Reported>' -ForEach @(
        @{ Reported = 'Norway East'; Selected = ' NORWAYEAST '; ResourceType = 'Microsoft.Example/parents/children' }
        @{ Reported = 'norwayeast'; Selected = 'Norway East'; ResourceType = 'Microsoft.DesktopVirtualization/hostpools' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Reported = $Reported; Selected = $Selected; ResourceType = $ResourceType } {
            param($Reported, $Selected, $ResourceType)
            $script:providerLocation.message = $script:providerLocation.message.Replace('norwayeast', $Reported).
                Replace('Microsoft.DesktopVirtualization/hostpools', $ResourceType)
            Test-AvmBicepRetryErrorNode -Node $script:providerLocation -ResourceLocation $Selected | Should -BeTrue
        }
    }

    It 'rejects incomplete or contradictory provider availability: <Mutation>' -ForEach @(
        @{ Mutation = 'generic wording' }, @{ Mutation = 'missing provider' }, @{ Mutation = 'resource ID' }
        @{ Mutation = 'missing region' }, @{ Mutation = 'global region' }, @{ Mutation = 'no selected region' }
        @{ Mutation = 'empty available regions' }, @{ Mutation = 'selected region available' }
        @{ Mutation = 'duplicate regions' }, @{ Mutation = 'malformed regions' }, @{ Mutation = 'uppercase regions' }
        @{ Mutation = 'global availability' }, @{ Mutation = 'trailing error' }, @{ Mutation = 'trailing newline' }
        @{ Mutation = 'code casing' }, @{ Mutation = 'unknown ancestor' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mutation = $Mutation } {
            param($Mutation)
            $node = $script:providerLocation
            $location = 'norwayeast'
            switch ($Mutation) {
                'generic wording' { $node.message = 'The resource is not available in this region.' }
                'missing provider' { $node.message = $node.message.Replace('Microsoft.DesktopVirtualization/hostpools', 'hostpools') }
                'resource ID' { $node.message = $node.message.Replace('Microsoft.DesktopVirtualization/hostpools', $script:resourcePrefix + 'Microsoft.DesktopVirtualization/hostpools/test') }
                'missing region' { $node.message = $node.message.Replace("'norwayeast'", "''") }
                'global region' { $node.message = $node.message.Replace('norwayeast', 'global'); $location = 'global' }
                'no selected region' { $location = '' }
                'empty available regions' { $node.message = $node.message.Replace('eastus,westeurope', '') }
                'selected region available' { $node.message = $node.message.Replace('eastus,westeurope', 'eastus,norwayeast') }
                'duplicate regions' { $node.message = $node.message.Replace('eastus,westeurope', 'eastus,eastus') }
                'malformed regions' { $node.message = $node.message.Replace('eastus,westeurope', 'eastus,,westeurope') }
                'uppercase regions' { $node.message = $node.message.Replace('eastus,westeurope', 'EASTUS,westeurope') }
                'global availability' { $node.message = $node.message.Replace('eastus,westeurope', 'global') }
                'trailing error' { $node.message += ' AuthorizationFailed.' }
                'trailing newline' { $node.message += "`n" }
                'code casing' { $node.code = 'locationnotavailableforresourcetype' }
                'unknown ancestor' { $node = @{ error = $node; unknown = $null } }
            }
            Test-AvmBicepRetryErrorNode -Node $node -ResourceLocation $location | Should -BeFalse
        }
    }

    It 'rejects mixed provider-location evidence in either order: <Sibling>' -ForEach @(
        @{ Sibling = 'authorization' }, @{ Sibling = 'unknown' }, @{ Sibling = 'unknown null field' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Sibling = $Sibling } {
            param($Sibling)
            $other = switch ($Sibling) {
                'authorization' { @{ code = 'AuthorizationFailed'; message = 'Denied.' } }
                'unknown' { @{ code = 'Unknown'; message = 'Regional failure.' } }
                'unknown null field' { @{ code = 'SkuNotAvailable'; message = 'SKU not available in this region.'; unknown = $null } }
            }
            foreach ($nodes in @(@($script:providerLocation, $other), @($other, $script:providerLocation))) {
                Test-AvmBicepRetryErrorNode -Node $nodes -ResourceLocation norwayeast | Should -BeFalse
            }
        }
    }

    It 'rejects malformed raw preflight JSON before optional-member normalization: <Mutation>' -ForEach @(
        @{ Mutation = 'duplicate code' }, @{ Mutation = 'duplicate target' }, @{ Mutation = 'case-duplicate target' }
        @{ Mutation = 'escaped duplicate target' }, @{ Mutation = 'trailing data' }, @{ Mutation = 'trailing comma' }
        @{ Mutation = 'comment' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mutation = $Mutation } {
            param($Mutation)
            $script:providerLocation.target = $null
            $json = $script:providerLocation | ConvertTo-Json -Compress
            $json = switch ($Mutation) {
                'duplicate code' { $json.Replace('"code":', '"code":"AuthorizationFailed","code":') }
                'duplicate target' { $json.Replace('"target":null', '"target":"foreign","target":null') }
                'case-duplicate target' { $json.Replace('"target":null', '"Target":"foreign","target":null') }
                'escaped duplicate target' { $json.Replace('"target":null', '"\u0074arget":"foreign","target":null') }
                'trailing data' { $json + ' Denied' }
                'trailing comma' { $json.Insert($json.Length - 1, ',') }
                'comment' { '/* Denied */' + $json }
            }
            $failure = [Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Safe validation summary.'), 'NativeFailure', 'InvalidResult', $null)
            $failure.ErrorDetails = [Management.Automation.ErrorDetails]::new($json)
            Test-AvmBicepRegionalValidationError -ErrorRecord $failure -ResourceLocation norwayeast | Should -BeFalse
        }
    }

    It 'never uses provider-location evidence to bypass <Boundary>' -ForEach @(
        @{ Boundary = 'HTTP 401'; Status = 401 }, @{ Boundary = 'HTTP 403'; Status = 403 }
        @{ Boundary = 'HTTP 429'; Status = 429 }, @{ Boundary = 'HTTP 500'; Status = 500 }
        @{ Boundary = 'HTTP 504'; Status = 504 }, @{ Boundary = 'string status'; Status = '400' }
        @{ Boundary = 'array status'; Status = @(400) }, @{ Boundary = 'Boolean status'; Status = $true }
        @{ Boundary = 'cancellation'; Status = $null }, @{ Boundary = 'permission category'; Status = $null }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Boundary = $Boundary; Status = $Status } {
            param($Boundary, $Status)
            $exception = if ($Boundary -eq 'cancellation') { [OperationCanceledException]::new('Cancelled.') }
            else { [InvalidOperationException]::new('Safe validation summary.') }
            if ($null -ne $Status) { $exception | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $Status } }
            $category = if ($Boundary -eq 'permission category') { 'PermissionDenied' } else { 'InvalidResult' }
            $failure = [Management.Automation.ErrorRecord]::new(
                $exception, 'AvmBicepTemplateValidationFailed', $category, $script:providerLocation)
            Test-AvmBicepRegionalValidationError -ErrorRecord $failure -ResourceLocation norwayeast | Should -BeFalse
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
