#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:Invoke-AzRestMethod {
            [CmdletBinding()]
            param($Method, $Path, $DefaultProfile)
            throw 'Unexpected Azure request.'
        }
        function script:Get-AzContext {
            [CmdletBinding()]
            param()
            throw 'Unexpected Azure context lookup.'
        }
        function script:New-AzResourceGroupDeployment {
            [CmdletBinding()]
            param($Name, $ResourceGroupName, $Mode, $Force, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt)
            throw 'Unexpected Azure deployment.'
        }
        function script:Test-AzResourceGroupDeployment {
            [CmdletBinding()]
            param($ResourceGroupName, $Mode, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt)
            throw 'Unexpected Azure validation.'
        }
        function script:New-AzSubscriptionDeployment {
            [CmdletBinding()]
            param($Name, $Location, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt)
            throw 'Unexpected Azure deployment.'
        }
        function script:New-AzManagementGroupDeployment {
            [CmdletBinding()]
            param($Name, $Location, $ManagementGroupId, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt, $DefaultProfile)
            throw 'Unexpected Azure deployment.'
        }
        function script:New-AzTenantDeployment {
            [CmdletBinding()]
            param($Name, $Location, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt)
            throw 'Unexpected Azure deployment.'
        }
    }

    function New-TestForbiddenFailure {
        param([string] $Shape = 'response', [AllowNull()] [object] $Status = [System.Net.HttpStatusCode]::Forbidden)

        $fault = [InvalidOperationException]::new('Original forbidden submission; private-submission-detail.')
        if ($Shape -eq 'http') {
            $fault = [Net.Http.HttpRequestException]::new(
                $fault.Message, $null, [Net.HttpStatusCode]::Forbidden)
        }
        elseif ($Shape -eq 'direct status') { $fault | Add-Member -NotePropertyName StatusCode -NotePropertyValue $Status }
        elseif ($Shape -ne 'message only') {
            $fault | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $Status }
        }
        switch ($Shape) {
            'inner' { $fault = [InvalidOperationException]::new('Wrapped submission.', $fault) }
            'aggregate' { $fault = [AggregateException]::new([Exception[]]@($fault)) }
            'mixed timeout' { $fault = [AggregateException]::new([Exception[]]@($fault, [TimeoutException]::new('Timeout.'))) }
            'mixed cancellation' { $fault = [AggregateException]::new([Exception[]]@($fault, [OperationCanceledException]::new('Cancelled.'))) }
            'pipeline cancellation' { $fault = [AggregateException]::new([Exception[]]@($fault, [Management.Automation.PipelineStoppedException]::new('Cancelled.'))) }
        }
        $record = [Management.Automation.ErrorRecord]::new($fault, 'OriginalForbidden', 'PermissionDenied', 'original-target')
        $record.ErrorDetails = [Management.Automation.ErrorDetails]::new('Private original diagnostic; operation fixture-id.')
        if ($Shape -eq 'runtime') {
            return [Management.Automation.RuntimeException]::new('Wrapped submission.', $null, $record)
        }
        return $record
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep native ARM operation' {
    It 'keeps authored parameter names and secure values inside TemplateParameterObject' {
        InModuleScope Avm.Authoring {
            Mock New-AzResourceGroupDeployment { @{ ProvisioningState = 'Succeeded' } }
            $password = [securestring]::new()
            $parameters = @{ Name = 'authored'; keys = @('one'); count = 0; password = $password }
            $null = Invoke-AvmBicepNativeArmOperation -Scope group -Operation Create -TemplatePath 'test.json' `
                -DeploymentName 'attempt' -MetadataLocation 'westus' -ResourceGroupName 'owned' -Parameters $parameters
            Should -Invoke New-AzResourceGroupDeployment -Exactly 1 -ParameterFilter {
                $Name -eq 'attempt' -and $ResourceGroupName -eq 'owned' -and $Mode -eq 'Incremental' -and
                $TemplateParameterObject['Name'] -eq 'authored' -and
                $TemplateParameterObject['count'] -eq 0 -and
                $TemplateParameterObject['password'] -is [securestring] -and $SkipTemplateParameterPrompt -and
                -not $Verbose -and -not $Debug
            }
        }
    }

    It 'routes higher scopes without adding unsupported mode or force flags: <Scope>' -ForEach @(
        @{ Scope = 'sub'; Command = 'New-AzSubscriptionDeployment' }
        @{ Scope = 'mg'; Command = 'New-AzManagementGroupDeployment' }
        @{ Scope = 'tenant'; Command = 'New-AzTenantDeployment' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Scope = $Scope; Command = $Command } {
            param($Scope, $Command)
            Mock $Command { @{ ProvisioningState = 'Succeeded' } }
            $null = Invoke-AvmBicepNativeArmOperation -Scope $Scope -Operation Create -TemplatePath 'test.json' `
                -DeploymentName 'attempt' -MetadataLocation 'westus' -ManagementGroupId 'test-mg'
            Should -Invoke $Command -Exactly 1 -ParameterFilter {
                $Name -eq 'attempt' -and $Location -eq 'westus' -and $SkipTemplateParameterPrompt
            }
        }
    }

    It 'retains structured validation errors without putting response messages in the public exception' {
        InModuleScope Avm.Authoring {
            Mock Test-AzResourceGroupDeployment {
                @{ Code = 'InvalidTemplateDeployment'; Details = @(@{
                            Code = 'AllocationFailed'; Message = 'Secret do-not-print capacity error in region.'
                        }) }
            }
            $errorRecord = $null
            try {
                Invoke-AvmBicepNativeArmOperation -Scope group -Operation Validate -TemplatePath 'test.json' `
                    -DeploymentName 'attempt' -MetadataLocation 'westus' -ResourceGroupName 'owned'
            }
            catch { $errorRecord = $_ }
            $errorRecord.FullyQualifiedErrorId | Should -BeLike 'AvmBicepTemplateValidationFailed*'
            $errorRecord.Exception.Message | Should -Not -Match 'do-not-print'
            (Test-AvmBicepRegionalValidationError -ErrorRecord $errorRecord) | Should -BeTrue
        }
    }

    It 'does not call Azure under WhatIf' {
        InModuleScope Avm.Authoring {
            Mock New-AzResourceGroupDeployment { throw 'Unexpected deployment.' }
            Invoke-AvmBicepNativeArmOperation -Scope group -Operation Create -TemplatePath 'test.json' `
                -DeploymentName 'attempt' -MetadataLocation 'westus' -ResourceGroupName 'owned' -WhatIf
            Should -Invoke New-AzResourceGroupDeployment -Exactly 0
        }
    }

    It 'forwards the exact management-group profile without changing authored parameters' {
        InModuleScope Avm.Authoring {
            $submissionProfile = @{ Tenant = @{ Id = 'original-tenant' } }
            Mock New-AzManagementGroupDeployment { @{ ProvisioningState = 'Succeeded' } }
            $null = Invoke-AvmBicepNativeArmOperation -Scope mg -Operation Create -TemplatePath 'test.json' `
                -DeploymentName 'attempt' -MetadataLocation 'westus' -ManagementGroupId 'test-mg' `
                -Parameters @{ DefaultProfile = 'authored-value' } -DefaultProfile $submissionProfile
            Should -Invoke New-AzManagementGroupDeployment -Exactly 1 -ParameterFilter {
                [object]::ReferenceEquals($DefaultProfile, $submissionProfile) -and
                $TemplateParameterObject['DefaultProfile'] -ceq 'authored-value'
            }
        }
    }
}

Describe 'Bicep native deployment retries' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:state = @{
                subscriptionId = '00000000-0000-0000-0000-000000000001'
                runId = '00000000000000000000000000000010'
                deployments = @()
            }
            $script:inputOptions = @{
                Scope = 'sub'; TemplatePath = 'test.json'; MetadataLocation = 'westus'
                Parameters = @{ baseTime = '2026-10-02 12:34:56Z' }
            }
            $script:persisted = @()
            Mock Save-AvmBicepCleanupState {
                $script:persisted = @($State['deployments'] | ForEach-Object { $_['id'] + ':' + $_['status'] })
            }
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
        }
    }

    It 'persists exact attempted IDs before submission and retains a stable baseTime through confirmed-failure retries' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepNativeArmOperation {
                $script:persisted[-1] | Should -BeLike "*/$DeploymentName`:Attempted"
                $Parameters['baseTime'] | Should -Be '2026-10-02 12:34:56Z'
                $id = "/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/$DeploymentName"
                if ($DeploymentName -like '*-t1') { return @{ Id = $id; ProvisioningState = 'Failed' } }
                return @{ Id = $id; ProvisioningState = 'Succeeded'; Outputs = @{ resourceId = @{ value = 'id' } } }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
            $result.Status | Should -Be 'pass'
            $script:state.deployments.Count | Should -Be 2
            $script:state.deployments[0].status | Should -Be 'Failed'
            $script:state.deployments[1].status | Should -Be 'Succeeded'
            $result.Outputs['resourceId']['value'] | Should -Be 'id'
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 2
            Should -Invoke Start-Sleep -Exactly 1
        }
    }

    It 'retries exact preflight rejection and preserves every rejected attempt for discovery' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepNativeArmOperation {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "10:20:30 - Error: Code=InvalidTemplateDeployment; Message=The template deployment '$DeploymentName' is not valid according to the validation procedure. Resource reported preflight validation errors."),
                    'NativeDeploymentError', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
            $result.Status | Should -Be 'fail'
            $script:state.deployments.Count | Should -Be 3
            @($script:state.deployments | Where-Object { $_.preflightRejected -and $_.status -eq 'Rejected' }).Count |
                Should -Be 3
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 3
        }
    }

    It 'watches the same deployment after a submission timeout: <Recovered>' -ForEach @(
        @{ Recovered = 'Succeeded'; Status = 'pass'; Submissions = 1 }
        @{ Recovered = 'Failed'; Status = 'pass'; Submissions = 2 }
        @{ Recovered = 'unreadable'; Status = 'fail'; Submissions = 1 }
    ) {
        InModuleScope Avm.Authoring -Parameters $_ {
            param($Recovered, $Status, $Submissions)
            Mock Invoke-AvmBicepNativeArmOperation {
                if ($DeploymentName -like '*-t1') { throw [System.TimeoutException]::new('Timed out.') }
                @{
                    Id = "/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/$DeploymentName"
                    ProvisioningState = 'Succeeded'
                }
            }
            Mock Wait-AvmBicepNativeDeployment {
                if ($Recovered -eq 'unreadable') { throw [System.TimeoutException]::new('Recovery timed out.') }
                [pscustomobject]@{ State = $Recovered; Outputs = @{ fromWatch = @{ value = 1 } } }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
            $result.Status | Should -Be $Status
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly $Submissions
            Should -Invoke Wait-AvmBicepNativeDeployment -Exactly 1 -ParameterFilter { $DeploymentId -like '*-t1' }
            switch ($Recovered) {
                'Succeeded' { $result.Outputs['fromWatch']['value'] | Should -Be 1 }
                'Failed' { $script:state.deployments[0].status | Should -Be 'Failed' }
                default { $result.Outcome | Should -Be 'Unknown'; $result.ErrorKind | Should -Be 'Timeout' }
            }
        }
    }

    It 'never resubmits an unknown outcome: <Failure>' -ForEach @(
        @{ Failure = 'transport' }, @{ Failure = 'null' }
        @{ Failure = 'running' }, @{ Failure = 'unclassified exception' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Failure = $Failure } {
            param($Failure)
            Mock Invoke-AvmBicepNativeArmOperation {
                switch ($Failure) {
                    'transport' { throw [System.Net.Http.HttpRequestException]::new('Transport failed.') }
                    'null' { return $null }
                    'running' {
                        return @{
                            Id = "/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/$DeploymentName"
                            ProvisioningState = 'Running'
                        }
                    }
                    default { throw [System.InvalidOperationException]::new('Unclassified.') }
                }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
            $result.Status | Should -Be 'fail'
            $result.Outcome | Should -Be 'Unknown'
            $script:state.deployments.Count | Should -Be 1
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'does not accept a terminal response without the exact attempted ID: <ResponseId> <Outcome>' -ForEach @(
        @{ ResponseId = $null; Outcome = 'Succeeded' }
        @{ ResponseId = '/another/deployment'; Outcome = 'Succeeded' }
        @{ ResponseId = $null; Outcome = 'Failed' }
        @{ ResponseId = '/another/deployment'; Outcome = 'Failed' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ ResponseId = $ResponseId; Outcome = $Outcome } {
            param($ResponseId, $Outcome)
            Mock Invoke-AvmBicepNativeArmOperation {
                [pscustomobject]@{ Id = $ResponseId; ProvisioningState = $Outcome }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
            $result.Status | Should -Be 'fail'
            $result.Outcome | Should -Be 'Unknown'
            $script:persisted[-1] | Should -BeLike '*:Unknown'
            $script:state.deployments.Count | Should -Be 1
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'retries a confirmed failure reported with an error summary: <Summary>' -ForEach @(
        @{ Summary = '' }
        @{ Summary = 'Showing 1 out of 1 error(s). Status Message: Quota exceeded. ' }
    ) {
        InModuleScope Avm.Authoring -Parameters $_ {
            param($Summary)
            Mock Invoke-AvmBicepNativeArmOperation {
                if ($DeploymentName -like '*-t1') {
                    throw [System.InvalidOperationException]::new(
                        "10:20:30 - The deployment '$DeploymentName' failed with error(s). $($Summary)(Code: DeploymentFailed)")
                }
                @{
                    Id = "/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/$DeploymentName"
                    ProvisioningState = 'Succeeded'
                }
            }
            $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
            $result.Status | Should -Be 'pass'
            $script:state.deployments[0].status | Should -Be 'Failed'
        }
    }

    It 'persists cancellation as unknown and propagates it without another submission' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepNativeArmOperation { throw [System.OperationCanceledException]::new('Canceled.') }
            { New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions } |
                Should -Throw -ExpectedMessage '*Canceled*'
            $script:persisted[-1] | Should -BeLike '*:Unknown'
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
        }
    }

    Context 'management-group authorization recovery' {
        BeforeEach {
            $submissionFailure = New-TestForbiddenFailure
            InModuleScope Avm.Authoring -Parameters @{ SubmissionFailure = $submissionFailure } {
                param($SubmissionFailure)
                $script:inputOptions.Scope = 'mg'
                $script:inputOptions.ManagementGroupId = 'test-mg'
                $script:submissionFailure = $SubmissionFailure
                $script:submittedProfile = @{
                    Subscription = @{ Id = $script:state.subscriptionId }
                    Tenant = @{ Id = '00000000-0000-0000-0000-000000000002' }
                }
                $script:ambientProfile = $script:submittedProfile
                $script:recoveryMode = 'Succeeded'
                $script:recoverySequence = [Collections.Generic.Queue[string]]::new()
                Mock Get-AzContext { $script:ambientProfile }
                Mock Invoke-AvmBicepNativeArmOperation { throw $script:submissionFailure }
                Mock Get-AvmBicepDeploymentRetryKind { throw 'Authorization recovery must not classify resource failures.' }
                Mock Invoke-AzRestMethod {
                    $id = $script:state.deployments[-1].id
                    $mode = if ($script:recoverySequence.Count -gt 0) { $script:recoverySequence.Dequeue() } else { $script:recoveryMode }
                    $document = @{
                        id = $id
                        properties = @{ provisioningState = 'Succeeded'; outputs = @{ recovered = @{ value = 'original-output' } } }
                    }
                    if ($mode -in @('Failed', 'Unknown', 'Canceled', 'Accepted', 'Running', 'Creating', 'Updating')) {
                        $document.properties.provisioningState = $mode
                    }
                    switch ($mode) {
                        'timeout' { throw [TimeoutException]::new('Read timeout.') }
                        'forbidden' { throw [Net.Http.HttpRequestException]::new('Read denied.', $null, [Net.HttpStatusCode]::Forbidden) }
                        'transport' { throw [Net.Http.HttpRequestException]::new('Read interrupted.') }
                        'cancelled' { throw [OperationCanceledException]::new('Read cancelled.') }
                        'missing' { return @{ StatusCode = 404; Content = '{}' } }
                        'wrong group' { $document.id = $id.Replace('/test-mg/', '/foreign-mg/') }
                        'missing ID' { $document.Remove('id') }
                        'array document' { $document = @($document) }
                        'array properties' { $document.properties = @($document.properties) }
                        'array ID' { $document.id = @($id) }
                        'array state' { $document.properties.provisioningState = @('Succeeded') }
                        'missing state' { $document.properties.Remove('provisioningState') }
                        'invalid outputs' { $document.properties.outputs = @('not-an-object') }
                    }
                    return @{ StatusCode = 200; Content = ConvertTo-Json -InputObject $document -Depth 6 -Compress }
                }
            }
        }

        It 'observes a typed <Shape> HTTP 403 once and recovers only the original outputs' -ForEach @(
            @{ Shape = 'response' }, @{ Shape = 'direct status' }, @{ Shape = 'http' }
            @{ Shape = 'inner' }, @{ Shape = 'aggregate' }, @{ Shape = 'runtime' }, @{ Shape = 'mixed timeout' }
        ) {
            $submissionFailure = New-TestForbiddenFailure -Shape $Shape
            InModuleScope Avm.Authoring -Parameters @{ SubmissionFailure = $submissionFailure } {
                param($SubmissionFailure)
                $script:submissionFailure = $SubmissionFailure
                $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' `
                    -DeploymentInput $script:inputOptions -AllowRelocation -AllowTransientRetry
                $result.Status | Should -Be 'pass'
                $result.Outputs.recovered.value | Should -BeExactly 'original-output'
                $script:state.deployments.Count | Should -Be 1
                $script:state.deployments[0].status | Should -Be 'Succeeded'
                $script:state.deployments[0].preflightRejected | Should -BeFalse
                Should -Invoke Get-AzContext -Exactly 1
                Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1 -ParameterFilter {
                    [object]::ReferenceEquals($DefaultProfile, $script:submittedProfile) -and
                    $ManagementGroupId -ceq 'test-mg' -and $Parameters.baseTime -ceq '2026-10-02 12:34:56Z'
                }
                Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter {
                    $Method -ceq 'GET' -and $Path -ceq "$($result.DeploymentId)?api-version=2021-04-01" -and
                    [object]::ReferenceEquals($DefaultProfile, $script:submittedProfile)
                }
                Should -Invoke Get-AvmBicepDeploymentRetryKind -Exactly 0
                Should -Invoke Start-Sleep -Exactly 0
            }
        }

        It 'keeps the original profile after the ambient context changes during submission' {
            InModuleScope Avm.Authoring {
                Mock Invoke-AvmBicepNativeArmOperation {
                    $script:ambientProfile = @{ Tenant = @{ Id = 'foreign' } }
                    throw $script:submissionFailure
                }
                $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
                $result.Status | Should -Be 'pass'
                Should -Invoke Get-AzContext -Exactly 1
                Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter {
                    [object]::ReferenceEquals($DefaultProfile, $script:submittedProfile)
                }
            }
        }

        It 'uses the captured profile for management-group timeout observation too' {
            InModuleScope Avm.Authoring {
                Mock Invoke-AvmBicepNativeArmOperation { throw [TimeoutException]::new('Timed out.') }
                (New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions).Status |
                    Should -Be 'pass'
                Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter {
                    [object]::ReferenceEquals($DefaultProfile, $script:submittedProfile)
                }
            }
        }

        It 'retains both diagnostics without replay or regional classification after <Recovery>' -ForEach @(
            @{ Recovery = 'Failed'; Outcome = 'Failed' }, @{ Recovery = 'Unknown'; Outcome = 'Unknown' }
            @{ Recovery = 'Canceled'; Outcome = 'Unknown' }, @{ Recovery = 'missing'; Outcome = 'Unknown' }
            @{ Recovery = 'wrong group'; Outcome = 'Unknown' }, @{ Recovery = 'missing ID'; Outcome = 'Unknown' }
            @{ Recovery = 'array document'; Outcome = 'Unknown' }, @{ Recovery = 'array properties'; Outcome = 'Unknown' }
            @{ Recovery = 'array ID'; Outcome = 'Unknown' }, @{ Recovery = 'array state'; Outcome = 'Unknown' }
            @{ Recovery = 'missing state'; Outcome = 'Unknown' }, @{ Recovery = 'invalid outputs'; Outcome = 'Unknown' }
            @{ Recovery = 'forbidden'; Outcome = 'Unknown' }, @{ Recovery = 'transport'; Outcome = 'Unknown' }
        ) {
            InModuleScope Avm.Authoring -Parameters @{ Recovery = $Recovery; Outcome = $Outcome } {
                param($Recovery, $Outcome)
                $script:recoveryMode = $Recovery
                $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' `
                    -DeploymentInput $script:inputOptions -AllowRelocation -AllowTransientRetry
                $result.Status | Should -Be 'fail'
                $result.Outcome | Should -Be $Outcome
                $result.ErrorKind | Should -Be 'Forbidden'
                $result.Outputs.Count | Should -Be 0
                $result.ErrorRecord.FullyQualifiedErrorId | Should -BeLike 'OriginalForbidden*'
                $result.ErrorRecord.ErrorDetails.Message | Should -BeExactly 'Private original diagnostic; operation fixture-id.'
                $result.ErrorRecord.TargetObject | Should -BeExactly 'original-target'
                $result.RecoveryErrorRecord | Should -Not -BeNullOrEmpty
                $script:state.deployments.Count | Should -Be 1
                $script:state.deployments[0].status | Should -Be $Outcome
                Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
                Should -Invoke Invoke-AzRestMethod -Exactly 1
                Should -Invoke Get-AvmBicepDeploymentRetryKind -Exactly 0
                Should -Invoke Start-Sleep -Exactly 0
                Should -Invoke Write-AvmLog -Exactly 0 -ParameterFilter { $Message -match 'private-submission-detail|Private original diagnostic' }
            }
        }

        It 'shares the existing bounded observation budget without spending a submission: <Sequence>' -ForEach @(
            @{ Sequence = 'active then success'; States = @('Accepted', 'timeout', 'Running', 'Creating', 'Updating', 'Succeeded'); Status = 'pass'; Reads = 6; Sleeps = 5 }
            @{ Sequence = 'consecutive timeouts'; States = @('timeout', 'timeout', 'timeout'); Status = 'fail'; Reads = 3; Sleeps = 2 }
        ) {
            InModuleScope Avm.Authoring -Parameters $_ {
                param($States, $Status, $Reads, $Sleeps)
                foreach ($value in $States) { $script:recoverySequence.Enqueue($value) }
                $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions -RetryLimit 1
                $result.Status | Should -Be $Status
                Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
                Should -Invoke Invoke-AzRestMethod -Exactly $Reads
                Should -Invoke Start-Sleep -Exactly $Sleeps -ParameterFilter { $Seconds -eq 15 }
            }
        }

        It 'does not observe wording or malformed <Evidence> as an HTTP 403' -ForEach @(
            @{ Evidence = 'message'; Shape = 'message only'; Status = $null }
            @{ Evidence = 'missing status'; Shape = 'response'; Status = $null }
            @{ Evidence = 'HTTP 401'; Shape = 'response'; Status = 401 }
            @{ Evidence = 'string'; Shape = 'response'; Status = '403' }
            @{ Evidence = 'Boolean'; Shape = 'response'; Status = $true }
            @{ Evidence = 'floating point'; Shape = 'response'; Status = 403.0 }
            @{ Evidence = 'single-item array'; Shape = 'response'; Status = @(403) }
            @{ Evidence = 'multiple statuses'; Shape = 'response'; Status = @(403, 401) }
        ) {
            $submissionFailure = New-TestForbiddenFailure -Shape $Shape -Status $Status
            InModuleScope Avm.Authoring -Parameters @{ SubmissionFailure = $submissionFailure } {
                param($SubmissionFailure)
                $script:submissionFailure = $SubmissionFailure
                $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
                $result.Status | Should -Be 'fail'
                $result.ErrorKind | Should -Not -Be 'Forbidden'
                Should -Invoke Invoke-AzRestMethod -Exactly 0
                Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
                Should -Invoke Start-Sleep -Exactly 0
            }
        }

        It 'does not extend HTTP 403 observation to <Scope> submissions' -ForEach @(
            @{ Scope = 'group' }, @{ Scope = 'sub' }, @{ Scope = 'tenant' }
        ) {
            InModuleScope Avm.Authoring -Parameters @{ Scope = $Scope } {
                param($Scope)
                $script:inputOptions.Scope = $Scope
                $script:inputOptions.ResourceGroupName = 'test-rg'
                $result = New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions
                $result.Status | Should -Be 'fail'
                $result.ErrorKind | Should -Be 'Forbidden'
                Should -Invoke Get-AzContext -Exactly 0
                Should -Invoke Invoke-AzRestMethod -Exactly 0
                Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
            }
        }

        It 'propagates <Shape> cancellation without authorization recovery' -ForEach @(
            @{ Shape = 'mixed cancellation' }, @{ Shape = 'pipeline cancellation' }
        ) {
            $submissionFailure = New-TestForbiddenFailure -Shape $Shape
            InModuleScope Avm.Authoring -Parameters @{ SubmissionFailure = $submissionFailure } {
                param($SubmissionFailure)
                $script:submissionFailure = $SubmissionFailure
                { New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions } |
                    Should -Throw '*Cancelled*'
                Should -Invoke Invoke-AzRestMethod -Exactly 0
                Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
            }
        }

        It 'propagates cancellation during observation without another status read or submission' {
            InModuleScope Avm.Authoring {
                $script:recoveryMode = 'cancelled'
                { New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions } |
                    Should -Throw '*cancelled*'
                Should -Invoke Invoke-AzRestMethod -Exactly 1
                Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
                $script:state.deployments[0].status | Should -Be 'Unknown'
            }
        }

        It 'does not record or submit without a usable original context: <Missing>' -ForEach @(
            @{ Missing = 'context' }, @{ Missing = 'tenant' }, @{ Missing = 'tenant ID' }, @{ Missing = 'context lookup denied' }
        ) {
            InModuleScope Avm.Authoring -Parameters @{ Missing = $Missing } {
                param($Missing)
                switch ($Missing) {
                    'context' { $script:ambientProfile = $null }
                    'tenant' { $script:ambientProfile.Tenant = $null }
                    'tenant ID' { $script:ambientProfile.Tenant.Id = ' ' }
                    'context lookup denied' { Mock Get-AzContext { throw $script:submissionFailure } }
                }
                { New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions } |
                    Should -Throw
                $script:state.deployments.Count | Should -Be 0
                Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 0
                Should -Invoke Invoke-AzRestMethod -Exactly 0
                Should -Invoke Save-AvmBicepCleanupState -Exactly 0
            }
        }

        It 'does not capture a profile or observe a deployment under WhatIf' {
            InModuleScope Avm.Authoring {
                (New-AvmBicepNativeDeployment -State $script:state -StatePath 'state.json' -DeploymentInput $script:inputOptions -WhatIf).Status |
                    Should -Be 'skipped'
                Should -Invoke Get-AzContext -Exactly 0
                Should -Invoke Invoke-AzRestMethod -Exactly 0
                Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 0
                $script:state.deployments.Count | Should -Be 0
            }
        }
    }
}

Describe 'Bicep native deployment timeout recovery' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/attempt'
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
        }
    }

    It 'polls until the exact deployment is terminal and returns its outputs: <Terminal>' -ForEach @(
        @{ Terminal = 'Succeeded' }, @{ Terminal = 'Failed' }
    ) {
        InModuleScope Avm.Authoring -Parameters $_ {
            param($Terminal)
            $script:reads = 0
            Mock Invoke-AzRestMethod {
                $script:reads++
                if ($script:reads -eq 1) { throw [System.TimeoutException]::new('Read timed out.') }
                $state = if ($script:reads -eq 2) { 'Running' } else { $Terminal }
                @{ StatusCode = 200; Content = (@{ id = $script:id; properties = @{
                                provisioningState = $state; outputs = @{ name = @{ type = 'String'; value = 'x' } } } } |
                        ConvertTo-Json -Depth 5) }
            }
            $result = Wait-AvmBicepNativeDeployment -DeploymentId $script:id -PollIntervalSeconds 0
            $result.State | Should -Be $Terminal
            $result.Outputs['name']['value'] | Should -Be 'x'
            Should -Invoke Invoke-AzRestMethod -Exactly 3 -ParameterFilter { $Method -eq 'GET' -and $Path -like "$script:id`?*" }
        }
    }

    It 'stops with an unknown outcome when recovery cannot confirm the deployment: <Condition>' -ForEach @(
        @{ Condition = 'three timeouts'; Message = '*three consecutive*' }
        @{ Condition = 'missing'; Message = '*HTTP 404*' }
        @{ Condition = 'wrong ID'; Message = '*did not return exactly*' }
        @{ Condition = 'unsupported state'; Message = "*unsupported recovery state 'Canceled'*" }
    ) {
        InModuleScope Avm.Authoring -Parameters $_ {
            param($Condition, $Message)
            Mock Invoke-AzRestMethod {
                switch ($Condition) {
                    'three timeouts' { throw [System.TimeoutException]::new('Read timed out.') }
                    'missing' { @{ StatusCode = 404; Content = '{}' } }
                    'wrong ID' { @{ StatusCode = 200; Content = '{"id":"/another","properties":{"provisioningState":"Succeeded"}}' } }
                    default {
                        @{ StatusCode = 200; Content = (@{ id = $script:id; properties = @{ provisioningState = 'Canceled' } } | ConvertTo-Json) }
                    }
                }
            }
            { Wait-AvmBicepNativeDeployment -DeploymentId $script:id -PollIntervalSeconds 0 } |
                Should -Throw -ExpectedMessage $Message
        }
    }

    It 'stops when the recovery window ends while the deployment is still running' {
        InModuleScope Avm.Authoring {
            Mock Start-Sleep { [System.Threading.Thread]::Sleep(1100) }
            Mock Invoke-AzRestMethod {
                @{ StatusCode = 200; Content = (@{ id = $script:id; properties = @{ provisioningState = 'Running' } } | ConvertTo-Json) }
            }
            { Wait-AvmBicepNativeDeployment -DeploymentId $script:id -TimeoutSeconds 1 -PollIntervalSeconds 1 } |
                Should -Throw -ExpectedMessage '*recovery window*'
        }
    }

    It 'rejects an untyped HTTP response status: <Label>' -ForEach @(
        @{ Label = 'null'; Value = $null }
        @{ Label = 'string'; Value = '200' }
        @{ Label = 'Boolean'; Value = $true }
        @{ Label = 'floating point'; Value = 200.0 }
        @{ Label = 'single-item array'; Value = @(200) }
        @{ Label = 'array'; Value = @(200, 403) }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Value = $Value } {
            param($Value)
            Mock Invoke-AzRestMethod {
                @{ StatusCode = $Value; Content = (@{ id = $script:id; properties = @{ provisioningState = 'Succeeded' } } | ConvertTo-Json) }
            }
            { Wait-AvmBicepNativeDeployment -DeploymentId $script:id } | Should -Throw '*invalid HTTP status*'
            Should -Invoke Invoke-AzRestMethod -Exactly 1
        }
    }

    It 'propagates cancellation while watching' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AzRestMethod { throw [System.OperationCanceledException]::new('Canceled.') }
            { Wait-AvmBicepNativeDeployment -DeploymentId $script:id -PollIntervalSeconds 0 } |
                Should -Throw -ExpectedMessage '*Canceled*'
            Should -Invoke Invoke-AzRestMethod -Exactly 1
        }
    }
}

Describe 'Bicep native deployment cleanup readiness' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/attempt'
            $script:state = @{ deployments = @(@{ id = $script:id; status = 'Unknown'; preflightRejected = $false }) }
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
        }
    }

    It 'waits for a terminal outcome before permitting cleanup' {
        InModuleScope Avm.Authoring {
            $script:requests = 0
            Mock Invoke-AzRestMethod {
                $script:requests++
                $state = if ($script:requests -eq 1) { 'Running' } else { 'Failed' }
                @{ StatusCode = 200; Content = (@{ id = $script:id; properties = @{ provisioningState = $state } } | ConvertTo-Json) }
            }
            $result = Get-AvmBicepPendingDeployment -State $script:state -RetryLimit 2 -RetryInterval 0
            $result.Pending.Count | Should -Be 0
            $script:state.deployments[0].status | Should -Be 'Failed'
            Should -Invoke Invoke-AzRestMethod -Exactly 2
        }
    }

    It 'retains missing, running, malformed and unreadable deployments: <Condition>' -ForEach @(
        @{ Condition = 'missing' }, @{ Condition = 'running' }, @{ Condition = 'wrong ID' }, @{ Condition = 'forbidden' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Condition = $Condition } {
            param($Condition)
            Mock Invoke-AzRestMethod {
                switch ($Condition) {
                    'missing' { @{ StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}' } }
                    'running' {
                        @{ StatusCode = 200; Content = (@{ id = $script:id; properties = @{ provisioningState = 'Running' } } | ConvertTo-Json) }
                    }
                    'wrong ID' {
                        @{ StatusCode = 200; Content = '{"id":"/another/deployment","properties":{"provisioningState":"Succeeded"}}' }
                    }
                    default { @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' } }
                }
            }
            $result = Get-AvmBicepPendingDeployment -State $script:state -RetryLimit 1
            $result.Pending | Should -Contain $script:id
            $result.Issues.Count | Should -Be 1
            $script:state.deployments[0].status | Should -Be 'Unknown'
        }
    }
}
