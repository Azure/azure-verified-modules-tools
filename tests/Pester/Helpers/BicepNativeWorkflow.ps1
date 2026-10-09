function New-NativeBicepWorkflowFixture {
    param([string] $TestRoot)

    $root = Join-Path $TestRoot ('native-' + [guid]::NewGuid().ToString('N'))
    $directory = Join-Path $root 'tests' 'e2e' 'defaults'
    $null = New-Item -ItemType Directory -Path $directory -Force
    Set-Content -LiteralPath (Join-Path $root 'main.bicep') -Value 'param name string'
    Set-Content -LiteralPath (Join-Path $directory 'main.test.bicep') -Value "param namePrefix string = '#_namePrefix_#'"
    $state = [pscustomobject]@{
        Root = $root; Directory = $directory
        StatePath = Join-Path $TestRoot ([guid]::NewGuid().ToString('N') + '.json')
        StatePaths = [Collections.Generic.HashSet[string]]::new()
        Schema = 'deploymentTemplate'; Compiled = $null
        Parameters = @{ resourceLocation = @{ type = 'string' }; baseTime = @{ type = 'string' } }
        Definitions = @{}; Resources = @(@{ type = 'Microsoft.Storage/storageAccounts'; name = '#_namePrefix_#' })
        RootResourceType = 'Microsoft.Authorization/policyDefinitions'
        Groups = @{}; Deployments = @{}; OperationMap = @{}
        RemovalSubscriptions = @{}; AdditionalRootResources = @()
        Calls = [Collections.Generic.List[object]]::new()
        NativeInputs = [Collections.Generic.List[object]]::new()
        RestInputs = [Collections.Generic.List[object]]::new()
        GroupLocations = [Collections.Generic.List[string]]::new()
        GroupAbsenceChecks = 0
        CurrentSubscription = '00000000-0000-0000-0000-000000000099'
        CurrentTenant = '00000000-0000-0000-0000-000000000002'
        IdentityMismatch = $false; GroupExists = $false; GroupCreateFails = $false
        OwnershipMismatch = $false; RetagDuringMetadata = $false
        ValidationFails = $false; ValidationError = $null; CreateMode = 'success'
        CleanupFails = $false; OutputMode = 'valid'; PesterMode = 'pass'; PostMode = 'pass'
        PesterInput = $null; HookInput = $null; FailuresRemaining = 0
        Nested = $false; NestedSubscription = ''; NestedResourceType = 'Microsoft.Storage/storageAccounts'
        NestedExtensions = @(); MissingOperations = $false; ReadinessState = 'Running'
        Outputs = @{ account = @{ type = 'String'; value = 'deployed-account' } }
        CreatedId = ''; LastDeploymentId = ''
        CreatedIds = [Collections.Generic.List[string]]::new()
        UseGeneratedNames = $false; FirstAttemptResources = @(); CancelAtAttempt = 0
        SubmissionError = $null
        RegionalFailures = 0; RegionalValidationFailures = 0; RegionalErrorFactory = $null; RecordDeleteFails = $false
        RetrySequence = [Collections.Generic.Queue[string]]::new()
        TransientResourceType = ''; TransientErrorCode = 'InternalServerError'; ThrowRetryFailure = $false
        NativeResponseMode = ''; RecordVisibilityReads = 0; RecordVisibilityAfterDeletion = 1
        RecordConfirmationDenied = $false; RecordVisibilityState = ''
        OperationLookupDenied = $false
        RemovedRecords = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    }
    & (Get-Module Avm.Authoring) {
        function script:Get-AzContext { [CmdletBinding()] param() throw 'Unmocked Azure context.' }
        function script:New-AzResourceGroup {
            [CmdletBinding()] param($Name, $Location, $Tag) throw 'Unmocked group creation.'
        }
        function script:Get-AzResourceGroup {
            [CmdletBinding()] param($Name) throw 'Unmocked group lookup.'
        }
        function script:Invoke-AzRestMethod {
            [CmdletBinding()] param($Method, $Path, $DefaultProfile) throw 'Unmocked Azure REST.'
        }
    }
    InModuleScope Avm.Authoring -Parameters @{ State = $state } {
        param($State)
        $script:nativeWorkflow = $State
        Mock Assert-AvmBicepAzureDependency {}
        Mock Get-Command { [pscustomobject]@{ Source = 'fake-az' } } -ParameterFilter { $Name -eq 'az' }
        Mock Resolve-AvmTool { [pscustomobject]@{ Path = 'fake-bicep'; Source = 'fixture'; Version = 'pinned' } }
        Mock Start-Sleep {}
        Mock Wait-AvmRetryDelay {}
        Mock Assert-AvmBicepAzureIdentity {
            if ($script:nativeWorkflow.IdentityMismatch) { throw [AvmConfigurationException]::new('Test identity mismatch.') }
        }
        Mock Invoke-AvmBicepAzureContext {
            $fixtureContext = $script:nativeWorkflow
            $originalSubscription = $fixtureContext.CurrentSubscription
            $originalTenant = $fixtureContext.CurrentTenant
            $fixtureContext.CurrentSubscription = [string]$SubscriptionId
            $fixtureContext.CurrentTenant = [string]$TenantId
            try { & $ScriptBlock }
            finally {
                $fixtureContext.CurrentSubscription = $originalSubscription
                $fixtureContext.CurrentTenant = $originalTenant
            }
        }
        Mock Get-AzContext {
            @{
                Subscription = @{ Id = $script:nativeWorkflow.CurrentSubscription }
                Tenant = @{ Id = $script:nativeWorkflow.CurrentTenant }
                Environment = @{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/' }
                Account = @{ Id = 'fixture-account' }
            }
        }
        Mock Get-AvmBicepResourceLocation {
            $region = @('eastus', 'centralus', 'westus2') | Where-Object { $_ -notin $UnavailableRegions } | Select-Object -First 1
            [pscustomobject]@{ Location = $region; IsGlobal = $false }
        }
        Mock Invoke-AvmProcess {
            if ($FilePath -ne 'fake-bicep' -or $ArgumentList[0] -ne 'build') {
                throw "Unmocked process: $FilePath"
            }
            $state = $script:nativeWorkflow
            $state.Calls.Add('compile')
            $json = if ($null -ne $state.Compiled) { $state.Compiled } else {
                @{
                    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/$($state.Schema).json#"
                    parameters = $state.Parameters; definitions = $state.Definitions; resources = $state.Resources
                } | ConvertTo-Json -Depth 100 -Compress
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = $json; StdErr = '' }
        }
        Mock Get-AzResourceGroup {
            $state = $script:nativeWorkflow
            if ($state.GroupExists) {
                return @{ ResourceId = "/subscriptions/$($state.CurrentSubscription)/resourceGroups/$Name"; Tags = @{} }
            }
            $group = $state.Groups[$Name]
            if ($null -ne $group -and $state.OwnershipMismatch) {
                return @{ ResourceId = $group.ResourceId; Tags = @{ 'avm-e2e-run-id' = 'foreign' } }
            }
            if ($null -eq $group) { throw [System.Exception]::new('Provided resource group does not exist.') }
            return $group
        }
        Mock New-AzResourceGroup {
            $state = $script:nativeWorkflow
            $state.Calls.Add('group-create')
            $state.GroupLocations.Add($Location)
            $runId = $Tag['avm-e2e-run-id']
            $path = if ($state.StatePath) { $state.StatePath } else {
                Join-Path ([IO.Path]::GetTempPath()) "avm-bicep-cleanup-$runId.json"
            }
            $null = $state.StatePaths.Add($path)
            $stored = Read-AvmBicepCleanupState -Path $path
            $stored['ownedResourceGroups'].Count | Should -Be ($state.Groups.Count + 1)
            $stored['ownedResourceGroups'][-1]['runId'] | Should -BeExactly $runId
            $stored['ownedResourceGroups'][-1]['id'] | Should -BeExactly "/subscriptions/$($state.CurrentSubscription)/resourceGroups/$Name"
            $group = @{
                ResourceId = "/subscriptions/$($state.CurrentSubscription)/resourceGroups/$Name"
                Tags = $Tag; Location = $Location
            }
            $state.Groups[$Name] = $group
            if ($state.GroupCreateFails) { throw [IO.IOException]::new('Group creation failed.') }
            return $group
        }
        Mock Invoke-AvmBicepNativeArmOperation {
            $state = $script:nativeWorkflow
            $state.Calls.Add($Operation.ToLowerInvariant())
            $runId = [regex]::Match($DeploymentName, '^avm-e2e-([0-9a-f]{32})-').Groups[1].Value
            $path = if ($state.StatePath) { $state.StatePath } else {
                Join-Path ([IO.Path]::GetTempPath()) "avm-bicep-cleanup-$runId.json"
            }
            $null = $state.StatePaths.Add($path)
            $state.NativeInputs.Add([pscustomobject]@{
                    Operation = $Operation; Parameters = $Parameters.Clone()
                    TemplatePath = $TemplatePath; Content = [IO.File]::ReadAllText($TemplatePath)
                    SubscriptionId = $state.CurrentSubscription; Scope = $Scope
                    Location = $MetadataLocation; ResourceGroupName = $ResourceGroupName
                    DefaultProfile = $DefaultProfile; DeploymentName = $DeploymentName
                })
            if ($Operation -eq 'Validate') {
                if ($state.ValidationFails) { throw [UnauthorizedAccessException]::new('Validation denied.') }
                if ($null -ne $state.ValidationError) { throw $state.ValidationError }
                if ($state.RegionalValidationFailures -gt 0) {
                    $state.RegionalValidationFailures--
                    $node = & $state.RegionalErrorFactory $Parameters['resourceLocation'] $null
                    throw [Management.Automation.ErrorRecord]::new(
                        [InvalidOperationException]::new('Safe regional validation failure.'),
                        'AvmBicepTemplateValidationFailed', 'InvalidResult', $node)
                }
                return
            }
            $id = Get-AvmBicepScopedDeploymentId -Scope $Scope -SubscriptionId $state.CurrentSubscription `
                -ManagementGroupId $ManagementGroupId -ResourceGroupName $ResourceGroupName -DeploymentName $DeploymentName
            $stored = Read-AvmBicepCleanupState -Path $path
            $stored['deployments'][-1]['id'] | Should -BeExactly $id
            $stored['deployments'][-1]['status'] | Should -Be 'Attempted'
            $ordinal = @($state.NativeInputs | Where-Object Operation -eq 'Create').Count
            $resourceName = if ($state.UseGeneratedNames) {
                ([IO.File]::ReadAllText($TemplatePath) | ConvertFrom-Json -AsHashtable).resources[0].name
            }
            else { 'example' }
            $target = if ($Scope -eq 'group') {
                "/subscriptions/$($state.CurrentSubscription)/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$resourceName"
            }
            else {
                $id.Substring(0, $id.LastIndexOf('/providers/Microsoft.Resources/deployments/')) +
                "/providers/$($state.RootResourceType)/$resourceName"
            }
            if ($state.TransientResourceType) {
                $targetGroup = if ($Scope -eq 'group') { $ResourceGroupName } else { "transient-$runId" }
                $target = "/subscriptions/$($state.CurrentSubscription)/resourceGroups/$targetGroup/providers/$($state.TransientResourceType)/$resourceName"
            }
            $state.CreatedId = $target
            $state.LastDeploymentId = $id
            $regional = $state.RegionalFailures -gt 0
            $transient = $false
            if ($state.RetrySequence.Count -gt 0) {
                $failureKind = $state.RetrySequence.Dequeue()
                $regional = $failureKind -eq 'Regional'
                $transient = $failureKind -eq 'Transient'
            }
            $provisioning = if ($regional) {
                if ($state.RegionalFailures -gt 0) { $state.RegionalFailures-- }
                'Failed'
            }
            elseif ($transient) {
                'Failed'
            }
            elseif ($state.FailuresRemaining -gt 0) {
                $state.FailuresRemaining--
                'Failed'
            }
            elseif ($state.CreateMode -eq 'failed') { 'Failed' }
            elseif ($state.CreateMode -in @('timeout', 'cancel', 'running', 'forbidden')) { $state.ReadinessState }
            else { 'Succeeded' }
            $state.Deployments[$id] = @{
                id = $id; properties = @{ provisioningState = $provisioning; outputs = $state.Outputs }
            }
            $state.OperationMap[$id] = @(@{
                    properties = @{ provisioningOperation = 'Create'; provisioningState = $provisioning; targetResource = @{ id = $target } }
                }, @{
                    properties = @{ provisioningOperation = 'Read'; provisioningState = 'Succeeded'; targetResource = @{ id = $target + '-existing' } }
                })
            if ($regional -or $transient) {
                $errorBody = if ($regional) {
                    if ($null -ne $state.RegionalErrorFactory) {
                        & $state.RegionalErrorFactory $Parameters['resourceLocation'] $target
                    }
                    else { @{ code = 'AllocationFailed'; message = 'Insufficient capacity in the region.' } }
                }
                else {
                    @{
                        code = 'ResourceDeploymentFailure'; target = $target
                        details = @(@{ code = $state.TransientErrorCode; message = 'Service temporarily failed.' })
                    }
                }
                $state.OperationMap[$id] = @(@{
                        properties = @{
                            provisioningOperation = 'Create'; provisioningState = 'Failed'; targetResource = @{ id = $target }
                            statusMessage = @{ error = $errorBody }
                        }
                    }, @{
                        properties = @{ provisioningOperation = 'Read'; provisioningState = 'Succeeded'; targetResource = @{ id = $target + '-existing' } }
                    })
            }
            if ($state.Nested) {
                $nestedSubscription = if ($state.NestedSubscription) { $state.NestedSubscription } else { $state.CurrentSubscription }
                $group = "/subscriptions/$nestedSubscription/resourceGroups/nested-$runId"
                $nested = "$group/providers/Microsoft.Resources/deployments/module"
                $target = "$group/providers/$($state.NestedResourceType)/example"
                $state.Deployments[$nested] = @{ id = $nested; properties = @{ provisioningState = $provisioning } }
                $state.OperationMap[$id] = @(
                    @{ properties = @{ provisioningOperation = 'Create'; provisioningState = 'Succeeded'; targetResource = @{ id = $group } } }
                    @{ properties = @{ provisioningOperation = 'Create'; provisioningState = $provisioning; targetResource = @{ id = $nested } } }
                )
                if ($regional -or $transient) { $state.OperationMap[$id][1].properties.statusMessage = @{ error = $errorBody } }
                $state.OperationMap[$nested] = @(
                    @{ properties = @{ provisioningOperation = 'Create'; provisioningState = $provisioning; targetResource = @{ id = $target } } }
                )
                foreach ($extension in $state.NestedExtensions) {
                    $state.OperationMap[$nested] += @{
                        properties = @{ provisioningOperation = 'Create'; provisioningState = 'Succeeded'; targetResource = @{ id = "$target/providers/$extension" } }
                    }
                }
                $state.CreatedId = $target
            }
            foreach ($additional in $state.AdditionalRootResources) {
                $state.OperationMap[$id] += @{
                    properties = @{ provisioningOperation = 'Create'; provisioningState = 'Succeeded'; targetResource = @{ id = $additional } }
                }
            }
            if ($ordinal -eq 1) {
                $historyId = if ($state.Nested) { $nested } else { $id }
                foreach ($additional in $state.FirstAttemptResources) {
                    $state.OperationMap[$historyId] += @{
                        properties = @{ provisioningOperation = 'Create'; provisioningState = 'Succeeded'; targetResource = @{ id = $additional } }
                    }
                }
            }
            $state.CreatedIds.Add($state.CreatedId)
            if ($ordinal -eq $state.CancelAtAttempt) { throw [OperationCanceledException]::new('Cancelled retry submission.') }
            if ($null -ne $state.SubmissionError) { throw $state.SubmissionError }
            if ($state.CreateMode -eq 'timeout') { throw [TimeoutException]::new('Submission timed out.') }
            if ($state.CreateMode -eq 'forbidden') {
                throw [Net.Http.HttpRequestException]::new(
                    'Forbidden submission with private-fixture-detail.', $null, [Net.HttpStatusCode]::Forbidden)
            }
            if ($state.CreateMode -eq 'cancel') { throw [OperationCanceledException]::new('Cancelled submission.') }
            if (($regional -or $transient) -and $state.ThrowRetryFailure) {
                throw [InvalidOperationException]::new('Native submission reported a resource failure.')
            }
            if ($state.NativeResponseMode -eq 'array-id') {
                return @{ Id = @($id); ProvisioningState = $provisioning; Outputs = $state.Outputs }
            }
            if ($state.NativeResponseMode -eq 'array-state') {
                return @{ Id = $id; ProvisioningState = @($provisioning); Outputs = $state.Outputs }
            }
            return @{ Id = $id; DeploymentName = $DeploymentName; ProvisioningState = $provisioning; Outputs = $state.Outputs }
        }
        Mock Invoke-AzRestMethod {
            $state = $script:nativeWorkflow
            $state.RestInputs.Add([pscustomobject]@{ Method = $Method; Path = $Path; DefaultProfile = $DefaultProfile })
            $recordId = $Path.Split('?')[0]
            if ($Method -eq 'DELETE' -and $state.Deployments.ContainsKey($recordId)) {
                $state.Calls.Add("delete-record:$recordId")
                if ($state.RecordDeleteFails) { return @{ StatusCode = 500; Content = '{}' } }
                $null = $state.RemovedRecords.Add($recordId)
                return @{ StatusCode = 202; Content = '' }
            }
            if ($Method -ne 'GET') { throw 'Unexpected mutating REST request.' }
            if ($state.RemovedRecords.Contains($recordId) -or $state.RemovedRecords.Contains(($recordId -replace '/operations$', ''))) {
                $state.Calls.Add("confirm-record:$recordId")
                if ($state.RecordConfirmationDenied) {
                    return @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
                }
                if ($state.RecordVisibilityReads -gt 0 -and $state.RemovedRecords.Count -ge $state.RecordVisibilityAfterDeletion -and
                    $state.Deployments.ContainsKey($recordId)) {
                    $state.RecordVisibilityReads--
                    if ($state.RecordVisibilityState) {
                        return @{
                            StatusCode = 200
                            Content = @{ id = $recordId; properties = @{ provisioningState = $state.RecordVisibilityState } } | ConvertTo-Json
                        }
                    }
                    return @{ StatusCode = 200; Content = $state.Deployments[$recordId] | ConvertTo-Json -Depth 20 }
                }
                return @{ StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}' }
            }
            $groupMatch = [regex]::Match($Path, '^/subscriptions/([^/]+)/resourceGroups/([^/?]+)\?api-version=2021-04-01$')
            if ($groupMatch.Success) {
                $groupMatch.Groups[1].Value | Should -BeExactly $state.CurrentSubscription
                $groupName = [uri]::UnescapeDataString($groupMatch.Groups[2].Value)
                $state.GroupAbsenceChecks++
                if ($state.GroupExists -or $state.Groups.ContainsKey($groupName)) {
                    return @{ StatusCode = 200; Content = '{}' }
                }
                return @{ StatusCode = 404; Content = '{"error":{"code":"ResourceGroupNotFound"}}' }
            }
            if ($Path.EndsWith('/operations?api-version=2025-04-01')) {
                $state.Calls.Add('discover')
                if ($state.OperationLookupDenied) {
                    return @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
                }
                $id = $Path.Substring(0, $Path.Length - '/operations?api-version=2025-04-01'.Length)
                if ($state.MissingOperations -or -not $state.OperationMap.ContainsKey($id)) {
                    return @{ StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}' }
                }
                return @{ StatusCode = 200; Content = (@{ value = $state.OperationMap[$id] } | ConvertTo-Json -Depth 20 -Compress) }
            }
            $state.Calls.Add('outputs')
            $id = $Path.Split('?')[0]
            if (-not $state.Deployments.ContainsKey($id)) { throw 'Unknown deployment lookup.' }
            $document = $state.Deployments[$id]
            if ($state.OutputMode -eq 'wrong-id') { $document = @{ id = $id + '-foreign'; properties = $document.properties } }
            if ($state.OutputMode -eq 'invalid') {
                $document = @{ id = $id; properties = @{ provisioningState = 'Succeeded'; outputs = @('not-an-object') } }
            }
            return @{ StatusCode = 200; Content = ($document | ConvertTo-Json -Depth 20 -Compress) }
        }
        Mock Invoke-AvmBicepPesterSuite {
            if (-not $InProcess) { throw 'Native assertions must retain the host session.' }
            $state = $script:nativeWorkflow
            $state.Calls.Add('pester')
            $state.PesterInput = $TestInputData
            $state.CurrentSubscription = '00000000-0000-0000-0000-000000000098'
            if ($state.PesterMode -eq 'throw') { throw [AvmProcessException]::new('Fixture assertion runner failure.') }
            if ($state.PesterMode -eq 'cancel') { throw [OperationCanceledException]::new('Fixture assertions cancelled.') }
            $summary = @{ Version = '5.7.1'; Total = 1; Passed = 1; Failed = 0; Skipped = 0; Inconclusive = 0; Filtered = 0; Issues = @() }
            switch ($state.PesterMode) {
                'fail' { $summary.Passed = 0; $summary.Failed = 1 }
                'skip' { $summary.Passed = 0; $summary.Skipped = 1 }
                'inconclusive' { $summary.Passed = 0; $summary.Inconclusive = 1 }
                'filtered' { $summary.Passed = 0; $summary.Filtered = 1; $summary.Total = 0 }
                'empty' { $summary.Total = 0; $summary.Passed = 0 }
            }
            return $summary
        }
        Mock Invoke-AvmBicepTestScript {
            $state = $script:nativeWorkflow
            if ([IO.Path]::GetFileName($Path) -cne 'post.ps1') { throw 'Unexpected authored script.' }
            $state.Calls.Add('post')
            $state.HookInput = $EnvVars
            $state.CurrentSubscription | Should -Be $EnvVars.AVM_E2E_SUBSCRIPTION_ID
            if ($state.PostMode -eq 'throw') { throw [AvmProcessException]::new('Fixture post failure.') }
            if ($state.PostMode -eq 'cancel') { throw [OperationCanceledException]::new('Fixture post cancelled.') }
            if ($state.PostMode -eq 'timeout') { throw [TimeoutException]::new('Fixture timeout.') }
            $exitCode = if ($state.PostMode -eq 'exit') { 19 } else { 0 }
            [pscustomobject]@{ ExitCode = $exitCode; Output = @() }
        }
        Mock Initialize-AvmBicepCleanupResource {
            $Resource['metadataCaptured'] = $true
            if ($script:nativeWorkflow.RetagDuringMetadata) { $script:nativeWorkflow.OwnershipMismatch = $true }
        }
        Mock Remove-AvmBicepResource {
            $state = $script:nativeWorkflow
            $state.Calls.Add("remove:$ResourceId")
            $state.RemovalSubscriptions[$ResourceId] = $state.CurrentSubscription
            if ($state.CleanupFails) { throw [IO.IOException]::new('Fixture removal failed.') }
            if ($Type -eq 'Microsoft.Resources/resourceGroups') { $state.Groups.Remove($ResourceId.Split('/')[-1]) }
        }
        Mock Remove-AvmBicepResourceRemainder { $script:nativeWorkflow.Calls.Add("purge:$ResourceId") }
    }
    return $state
}

function Get-NativeBicepWorkflowOptions {
    param($Fixture)
    @{
        Path = $Fixture.Root; SubscriptionId = '00000000-0000-0000-0000-000000000001'
        TenantId = '00000000-0000-0000-0000-000000000002'; Location = 'westus'
        ResourceLocation = 'eastus'; ResourceGroupPrefix = 'avm-e2e'
        CleanupStatePath = $Fixture.StatePath; SkipModuleVersionCheck = $true
    }
}

function Remove-NativeBicepWorkflowFixture {
    param($Fixture)
    foreach ($path in @($Fixture.StatePaths) + @($Fixture.StatePath)) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { Remove-Item -LiteralPath $path -Force }
    }
}
