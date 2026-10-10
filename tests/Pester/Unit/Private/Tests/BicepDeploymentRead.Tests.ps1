#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:Get-AzContext { [CmdletBinding()] param() throw 'Unexpected Azure context.' }
        function script:Invoke-AzRestMethod {
            [CmdletBinding()] param($Method, $Path, $DefaultProfile) throw 'Unexpected Azure REST.'
        }
    }
    function New-NestedReadError {
        $message = "Deployment 'module' could not be found."
        $fault = [InvalidOperationException]::new('Nested operation read failed.')
        $fault | Add-Member -NotePropertyName Request -NotePropertyValue @{
            Method = [Net.Http.HttpMethod]::Get
            RequestUri = [uri]'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Resources/deployments/module/operations?api-version=2025-04-01'
        }
        $fault | Add-Member -NotePropertyName Response -NotePropertyValue @{
            StatusCode = [Net.HttpStatusCode]::NotFound
            Content = @{ error = @{ code = 'DeploymentNotFound'; message = $message } } | ConvertTo-Json -Compress
        }
        $fault | Add-Member -NotePropertyName Body -NotePropertyValue @{ Code = 'DeploymentNotFound'; Message = $message }
        $record = [Management.Automation.ErrorRecord]::new($fault, 'NestedReadFixture', 'InvalidResult', 'original-target')
        $record.ErrorDetails = [Management.Automation.ErrorDetails]::new('Private nested-read diagnostic.')
        return $record
    }
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep native nested deployment read evidence' {
    BeforeEach {
        $script:failure = New-NestedReadError
        $script:root = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/root'
        $script:profile = @{
            Subscription = @{ Id = '00000000-0000-0000-0000-000000000001' }
            Environment = @{ ResourceManagerUrl = 'https://management.azure.com/' }
        }
    }

    It 'recognizes only complete nested GET404 evidence through <Wrapper>' -ForEach @(
        @{ Wrapper = 'direct' }, @{ Wrapper = 'inner' }, @{ Wrapper = 'aggregate' }, @{ Wrapper = 'runtime' }
    ) {
        $fault = $script:failure.Exception
        switch ($Wrapper) {
            'inner' { $fault = [InvalidOperationException]::new('Outer request.', $fault) }
            'aggregate' { $fault = [AggregateException]::new([Exception[]]@($fault)) }
            'runtime' { $fault = [Management.Automation.RuntimeException]::new('Outer request.', $null, $script:failure) }
        }
        $record = [Management.Automation.ErrorRecord]::new($fault, 'OuterFixture', 'InvalidResult', $null)
        InModuleScope Avm.Authoring -Parameters @{ Record = $record; Root = $script:root; Profile = $script:profile } {
            param($Record, $Root, $Profile)
            Test-AvmBicepNestedDeploymentReadFailure -ErrorRecord $Record -DeploymentId $Root -DefaultProfile $Profile |
                Should -BeTrue
        }
    }

    It 'rejects unsafe or ambiguous nested read evidence: <Invalid>' -ForEach @(
        @{ Invalid = 'foreign subscription' }, @{ Invalid = 'foreign profile' }, @{ Invalid = 'same root name' }
        @{ Invalid = 'foreign authority' }, @{ Invalid = 'HTTP' }, @{ Invalid = 'userinfo' }, @{ Invalid = 'fragment' }
        @{ Invalid = 'extra query' }, @{ Invalid = 'POST' }, @{ Invalid = 'array method' }, @{ Invalid = 'array URI' }
        @{ Invalid = 'untyped status' }, @{ Invalid = 'array status' }, @{ Invalid = 'array content' }
        @{ Invalid = 'array SDK code' }, @{ Invalid = 'wrong SDK message' }, @{ Invalid = 'missing SDK body' }
        @{ Invalid = 'duplicate JSON' }, @{ Invalid = 'extra JSON error' }, @{ Invalid = 'wrong raw target' }
        @{ Invalid = 'array envelope' }, @{ Invalid = 'mixed exception' }, @{ Invalid = 'runtime independent cause' }
        @{ Invalid = 'cancellation' }, @{ Invalid = 'authentication category' }, @{ Invalid = 'outer HTTP 403' }
    ) {
        $fault = $script:failure.Exception
        $uri = $fault.Request.RequestUri.AbsoluteUri
        $category = [Management.Automation.ErrorCategory]::InvalidResult
        switch ($Invalid) {
            'foreign subscription' { $fault.Request.RequestUri = $uri.Replace('000000000001', '000000000003') }
            'foreign profile' { $script:profile.Subscription.Id = '00000000-0000-0000-0000-000000000003' }
            'same root name' { $script:root = $script:root.Replace('/root', '/module') }
            'foreign authority' { $fault.Request.RequestUri = $uri.Replace('management.azure.com', 'example.invalid') }
            'HTTP' { $fault.Request.RequestUri = $uri.Replace('https:', 'http:') }
            'userinfo' { $fault.Request.RequestUri = $uri.Replace('https://', 'https://user@') }
            'fragment' { $fault.Request.RequestUri = $uri + '#fragment' }
            'extra query' { $fault.Request.RequestUri = $uri + '&extra=true' }
            'POST' { $fault.Request.Method = 'POST' }
            'array method' { $fault.Request.Method = @('GET') }
            'array URI' { $fault.Request.RequestUri = @($uri) }
            'untyped status' { $fault.Response.StatusCode = '404' }
            'array status' { $fault.Response.StatusCode = @(404) }
            'array content' { $fault.Response.Content = @($fault.Response.Content) }
            'array SDK code' { $fault.Body.Code = @('DeploymentNotFound') }
            'wrong SDK message' { $fault.Body.Message = "Deployment 'foreign' could not be found." }
            'missing SDK body' { $fault.Body = $null }
            'duplicate JSON' { $fault.Response.Content = $fault.Response.Content.Replace('"code":', '"code":"AuthorizationFailed","code":') }
            'extra JSON error' {
                $body = $fault.Response.Content | ConvertFrom-Json -AsHashtable
                $body.error['details'] = @(@{ code = 'AuthorizationFailed' })
                $fault.Response.Content = $body | ConvertTo-Json -Depth 10 -Compress
            }
            'wrong raw target' {
                $body = $fault.Response.Content | ConvertFrom-Json -AsHashtable
                $body.error['target'] = '/foreign'
                $fault.Response.Content = $body | ConvertTo-Json -Compress
            }
            'array envelope' { $fault.Response.Content = '[' + $fault.Response.Content + ']' }
            'mixed exception' { $fault = [AggregateException]::new([Exception[]]@($fault, [InvalidOperationException]::new('Unknown.'))) }
            'runtime independent cause' { $fault = [Management.Automation.RuntimeException]::new('Outer request.', [TimeoutException]::new(), $script:failure) }
            'cancellation' { $fault = [AggregateException]::new([Exception[]]@($fault, [OperationCanceledException]::new())) }
            'authentication category' { $category = [Management.Automation.ErrorCategory]::AuthenticationError }
            'outer HTTP 403' {
                $fault = [InvalidOperationException]::new('Outer request.', $fault)
                $fault | Add-Member -NotePropertyName StatusCode -NotePropertyValue 403
            }
        }
        $record = [Management.Automation.ErrorRecord]::new($fault, 'UnsafeFixture', $category, $null)
        InModuleScope Avm.Authoring -Parameters @{ Record = $record; Root = $script:root; Profile = $script:profile } {
            param($Record, $Root, $Profile)
            Test-AvmBicepNestedDeploymentReadFailure -ErrorRecord $Record -DeploymentId $Root -DefaultProfile $Profile |
                Should -BeFalse
        }
    }
}

Describe 'Bicep native original-root read recovery' {
    BeforeEach {
        $record = New-NestedReadError
        InModuleScope Avm.Authoring -Parameters @{ Record = $record } {
            param($Record)
            $script:submissionError = $Record
            $script:readState = @{
                runId = '0123456789abcdef0123456789abcdef'
                subscriptionId = '00000000-0000-0000-0000-000000000001'; deployments = @()
            }
            $script:readInput = @{ Scope = 'sub'; TemplatePath = 'template.json'; MetadataLocation = 'westus'; Parameters = @{} }
            $script:originalProfile = @{
                Subscription = @{ Id = $script:readState.subscriptionId }
                Tenant = @{ Id = '00000000-0000-0000-0000-000000000002' }
                Environment = @{ ResourceManagerUrl = 'https://management.azure.com/' }
            }
            $script:activeProfile = $script:originalProfile
            $script:recoveryMode = 'Succeeded'
            Mock Save-AvmBicepCleanupState {}
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
            Mock Get-AzContext { $script:activeProfile }
            Mock Invoke-AvmBicepNativeArmOperation {
                $script:activeProfile = @{ Tenant = @{ Id = 'foreign' } }
                throw $script:submissionError
            }
            Mock Get-AvmBicepDeploymentRetryKind { 'None' }
            Mock Invoke-AzRestMethod {
                $id = $script:readState.deployments[0].id
                $body = @{ id = $id; properties = @{ provisioningState = $script:recoveryMode; outputs = @{ recovered = @{ value = 'original' } } } }
                switch ($script:recoveryMode) {
                    'wrong root' { $body.id = $id.Replace('-t1', '-t2'); $body.properties.provisioningState = 'Succeeded' }
                    'malformed output' { $body.properties.outputs = @('invalid'); $body.properties.provisioningState = 'Succeeded' }
                    'mixed error' { $body['error'] = @{ code = 'AuthorizationFailed' }; $body.properties.provisioningState = 'Succeeded' }
                    'missing' { return @{ StatusCode = 404; Content = '{}' } }
                    'timeout' { throw [TimeoutException]::new('Status read timed out.') }
                    'cancel' { throw [OperationCanceledException]::new('Status read cancelled.') }
                }
                @{ StatusCode = 200; Content = $body | ConvertTo-Json -Depth 10 -Compress }
            }
        }
    }

    It 'recovers only the original root and profile without another submission' {
        InModuleScope Avm.Authoring {
            $result = New-AvmBicepNativeDeployment -State $script:readState -StatePath state.json -DeploymentInput $script:readInput -ClassifyRetry
            $result.Status | Should -Be 'pass'
            $result.Outputs.recovered.value | Should -BeExactly 'original'
            $result.ErrorRecord.ErrorDetails.Message | Should -BeExactly 'Private nested-read diagnostic.'
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1 -ParameterFilter {
                [object]::ReferenceEquals($DefaultProfile, $script:originalProfile)
            }
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter {
                $Method -ceq 'GET' -and $Path -ceq "$($result.DeploymentId)?api-version=2021-04-01" -and
                [object]::ReferenceEquals($DefaultProfile, $script:originalProfile)
            }
            Should -Invoke Get-AvmBicepDeploymentRetryKind -Exactly 0
        }
    }

    It 'requires separately confirmed eligible failures after recovered Failed status' {
        InModuleScope Avm.Authoring {
            $script:recoveryMode = 'Failed'
            Mock Get-AvmBicepDeploymentRetryKind { 'Transient' }
            $result = New-AvmBicepNativeDeployment -State $script:readState -StatePath state.json -DeploymentInput $script:readInput -ClassifyRetry
            $result.Status | Should -Be 'fail'
            $result.Outcome | Should -Be 'Failed'
            $result.RetryMode | Should -Be 'InPlace'
            Should -Invoke Get-AvmBicepDeploymentRetryKind -Exactly 1 -ParameterFilter {
                $DeploymentId -ceq $result.DeploymentId -and $null -eq $Failure
            }
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
        }
    }

    It 'retains original and recovery errors without replay after <Failure>' -ForEach @(
        @{ Failure = 'wrong root'; Reads = 1 }, @{ Failure = 'malformed output'; Reads = 1 }
        @{ Failure = 'mixed error'; Reads = 1 }, @{ Failure = 'missing'; Reads = 1 }, @{ Failure = 'Unknown'; Reads = 1 }
        @{ Failure = 'timeout'; Reads = 3 }, @{ Failure = 'classification'; Reads = 1 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Failure = $Failure; Reads = $Reads } {
            param($Failure, $Reads)
            $script:recoveryMode = $Failure
            if ($Failure -eq 'classification') {
                $script:recoveryMode = 'Failed'
                Mock Get-AvmBicepDeploymentRetryKind { throw [InvalidOperationException]::new('Failure history unavailable.') }
            }
            $result = New-AvmBicepNativeDeployment -State $script:readState -StatePath state.json -DeploymentInput $script:readInput -ClassifyRetry
            $result.Status | Should -Be 'fail'
            $result.RetryMode | Should -Be ''
            $result.ErrorRecord.ErrorDetails.Message | Should -BeExactly 'Private nested-read diagnostic.'
            $result.ErrorRecord.TargetObject | Should -BeExactly 'original-target'
            $result.RecoveryErrorRecord | Should -Not -BeNullOrEmpty
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
            Should -Invoke Invoke-AzRestMethod -Exactly $Reads
            Should -Invoke Write-AvmLog -Exactly 0 -ParameterFilter { $Message -match 'Private nested-read diagnostic' }
            if ($Failure -eq 'timeout') {
                $result.RecoveryErrorRecord.Exception.Data['ReadErrorRecord'].Exception | Should -BeOfType ([TimeoutException])
            }
        }
    }

    It 'preserves cancellation and the recorded root without attempting classification' {
        InModuleScope Avm.Authoring {
            $script:recoveryMode = 'cancel'
            { New-AvmBicepNativeDeployment -State $script:readState -StatePath state.json -DeploymentInput $script:readInput -ClassifyRetry } |
                Should -Throw -ExceptionType ([OperationCanceledException])
            $script:readState.deployments.Count | Should -Be 1
            $script:readState.deployments[0].status | Should -Be 'Unknown'
            Should -Invoke Get-AvmBicepDeploymentRetryKind -Exactly 0
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
        }
    }
}
