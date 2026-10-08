#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    . (Join-Path $PSScriptRoot '..' '..' '..' 'Helpers' 'BicepServiceRetry.ps1')
}

AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep service regional retry: <Kind>' -ForEach @(
    @{ Kind = 'SearchSku' }, @{ Kind = 'SearchSemantic' }
    @{ Kind = 'ContainerApps' }, @{ Kind = 'ContainerAppsNewCluster' }
) {
    BeforeEach {
        $fixture = New-BicepServiceRetryFixture -Kind $Kind
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $fixture } {
            param($Fixture)
            $script:service = $Fixture
            $script:failure = [Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Original service failure.'),
                'AvmBicepTemplateValidationFailed', 'InvalidResult', $Fixture.Response)
            $script:failure.ErrorDetails = [Management.Automation.ErrorDetails]::new('Sanitized display is not retry evidence.')
            $script:input = @{
                ErrorRecord = $script:failure; SubscriptionId = $Fixture.SubscriptionId; ResourceLocation = $Fixture.Region
            }
        }
    }

    It 'accepts synthetic complete <Source> evidence without modifying the original response' -ForEach @(
        @{ Source = 'ARM object' }, @{ Source = 'raw JSON' }
        @{ Source = 'SDK optional nulls' }, @{ Source = 'generic list' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Source = $Source } {
            param($Source)
            $original = $script:service.Response | ConvertTo-Json -Depth 30 -Compress
            $node = $script:service.Response
            if ($Source -eq 'raw JSON') { $node = $original }
            if ($Source -eq 'SDK optional nulls') {
                $node = $original | ConvertFrom-Json
                $leaf = $node.error
                while ($leaf.PSObject.Properties['details']) { $leaf = $leaf.details[0] }
                $leaf | Add-Member -NotePropertyName Target -NotePropertyValue $null
                $leaf | Add-Member -NotePropertyName Details -NotePropertyValue $null
            }
            if ($Source -eq 'generic list') {
                $node = [Collections.Generic.List[object]]::new()
                $node.Add($script:service.Response)
            }
            $snapshot = ConvertTo-Json -InputObject $node -Depth 30 -Compress
            $failure = [Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Original service failure.'),
                $(if ($Source -eq 'raw JSON') { 'NativeFailure' } else { 'AvmBicepTemplateValidationFailed' }),
                'InvalidResult', $node)
            $failure.ErrorDetails = [Management.Automation.ErrorDetails]::new(
                $(if ($Source -eq 'raw JSON') { $original } else { 'Sanitized display is not retry evidence.' }))
            $detail = $failure.ErrorDetails.Message
            Test-AvmBicepRegionalValidationError -ErrorRecord $failure `
                -SubscriptionId $script:service.SubscriptionId -ResourceLocation $script:service.Region | Should -BeTrue
            Test-AvmBicepRetryErrorNode -Node $script:service.Response -RetryKind Transient `
                -SubscriptionId $script:service.SubscriptionId -ResourceLocation $script:service.Region | Should -BeFalse
            [object]::ReferenceEquals($failure.TargetObject, $node) | Should -BeTrue
            $failure.Exception.Message | Should -BeExactly 'Original service failure.'
            $failure.ErrorDetails.Message | Should -BeExactly $detail
            (ConvertTo-Json -InputObject $node -Depth 30 -Compress) | Should -BeExactly $snapshot
            ($script:service.Response | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $original
        }
    }

    It 'accepts consistent service and <Scope> deployment targets with a display-name region' -ForEach @(
        @{ Scope = 'subscription'; Segment = '' }
        @{ Scope = 'resource group'; Segment = '/resourceGroups/retry-fixture' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Segment = $Segment } {
            param($Segment)
            $script:service.Leaf.target = $script:service.ResourceId.ToUpperInvariant()
            $script:service.Leaf.message = $script:service.Leaf.message.Replace('eastus', 'East US')
            $node = @{
                code = 'DeploymentFailed'
                target = "/subscriptions/$($script:service.SubscriptionId)$Segment/providers/Microsoft.Resources/deployments/root"
                details = @($script:service.Response)
            }
            Test-AvmBicepRetryErrorNode -Node $node -SubscriptionId $script:service.SubscriptionId -ResourceLocation ' EASTUS ' |
                Should -BeTrue
        }
    }

    It 'rejects a missing, global, secondary or malformed selected region: <Region>' -ForEach @(
        @{ Region = '' }, @{ Region = 'global' }, @{ Region = 'westus2' }, @{ Region = 'eastus,centralus' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Region = $Region } {
            param($Region)
            $script:input.ResourceLocation = $Region
            Test-AvmBicepRegionalValidationError @script:input | Should -BeFalse
        }
    }

    It 'requires the complete provider message: <Change>' -ForEach @(
        @{ Change = 'generic text' }, @{ Change = 'wrong code' }, @{ Change = 'code casing' }
        @{ Change = 'trailing failure' }, @{ Change = 'redacted region' }, @{ Change = 'global region' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Change = $Change } {
            param($Change)
            $leaf = $script:service.Leaf
            switch ($Change) {
                'generic text' { $leaf.message = 'Capacity is unavailable in region eastus.' }
                'wrong code' { $leaf.code = 'AuthorizationFailed' }
                'code casing' { $leaf.code = $leaf.code.ToLowerInvariant() }
                'trailing failure' { $leaf.message += ' AuthorizationFailed.' }
                'redacted region' { $leaf.message = $leaf.message.Replace('eastus', '[REDACTED]') }
                'global region' { $leaf.message = $leaf.message.Replace('eastus', 'global'); $script:input.ResourceLocation = 'global' }
            }
            Test-AvmBicepRegionalValidationError @script:input | Should -BeFalse
        }
    }

    It 'rejects unclassified <Field> fields' -ForEach @(
        @{ Field = 'additionalInfo'; Value = $null }, @{ Field = 'unknown'; Value = $null }
        @{ Field = 'details'; Value = @() }, @{ Field = 'innererror'; Value = $null }
        @{ Field = 'target'; Value = '' }, @{ Field = 'target'; Value = @('resource') }
        @{ Field = 'message'; Value = @('text') }, @{ Field = 'message'; Value = '' }, @{ Field = 'message'; Value = $null }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Field = $Field; Value = $Value } {
            param($Field, $Value)
            $script:service.Leaf[$Field] = $Value
            Test-AvmBicepRegionalValidationError @script:input | Should -BeFalse
        }
    }

    It 'rejects inconsistent target context: <Change>' -ForEach @(
        @{ Change = 'foreign subscription' }, @{ Change = 'foreign provider' }, @{ Change = 'partial ID' }
        @{ Change = 'non-resource target' }, @{ Change = 'missing subscription' }, @{ Change = 'invalid subscription' }
        @{ Change = 'empty subscription GUID' }, @{ Change = 'conflicting ancestor' }, @{ Change = 'another service' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Change = $Change } {
            param($Change)
            $script:service.Leaf.target = $script:service.ResourceId
            $node = $script:service.Response
            switch ($Change) {
                'foreign subscription' {
                    $script:service.Leaf.target = $script:service.ResourceId.Replace($script:service.SubscriptionId, '22222222-2222-2222-2222-222222222222')
                }
                'foreign provider' { $script:service.Leaf.target = $script:service.ResourceId.Replace($script:service.Provider, 'Microsoft.Storage/storageAccounts') }
                'partial ID' { $script:service.Leaf.target = "/providers/$($script:service.Provider)/service" }
                'non-resource target' { $script:service.Leaf.target = 'resourceLocation' }
                'missing subscription' { $script:input.SubscriptionId = '' }
                'invalid subscription' { $script:input.SubscriptionId = 'not-a-subscription' }
                'empty subscription GUID' { $script:input.SubscriptionId = [guid]::Empty.ToString() }
                'conflicting ancestor' {
                    $node = @{
                        code = 'DeploymentFailed'
                        target = '/subscriptions/22222222-2222-2222-2222-222222222222/providers/Microsoft.Resources/deployments/foreign'
                        details = @($node)
                    }
                }
                'another service' {
                    $node = @{ code = 'ResourceDeploymentFailure'; target = $script:service.ResourceId + '-other'; details = @($node) }
                }
            }
            Test-AvmBicepRetryErrorNode -Node $node -SubscriptionId $script:input.SubscriptionId -ResourceLocation eastus | Should -BeFalse
        }
    }

    It 'rejects mixed evidence in either sibling order: <Sibling>' -ForEach @(
        @{ Sibling = 'permission' }, @{ Sibling = 'configuration' }, @{ Sibling = 'unknown information' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Sibling = $Sibling } {
            param($Sibling)
            $other = switch ($Sibling) {
                'permission' { @{ code = 'AuthorizationFailed'; message = 'Forbidden.' } }
                'configuration' { @{ code = 'InvalidParameter'; message = 'Invalid setting.' } }
                'unknown information' { @{ code = 'SkuNotAvailable'; message = 'SKU not available in this region.'; unknown = $null } }
            }
            foreach ($nodes in @(@($script:service.Response, $other), @($other, $script:service.Response))) {
                Test-AvmBicepRetryErrorNode -Node $nodes -SubscriptionId $script:service.SubscriptionId -ResourceLocation eastus | Should -BeFalse
            }
        }
    }

    It 'rejects ambiguous raw JSON: <Form>' -ForEach @(
        @{ Form = 'duplicate code' }, @{ Form = 'escaped duplicate code' }, @{ Form = 'case-duplicate code' }
        @{ Form = 'trailing comma' }, @{ Form = 'comment' }, @{ Form = 'trailing data' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Form = $Form } {
            param($Form)
            $json = $script:service.Response | ConvertTo-Json -Depth 30 -Compress
            $json = switch ($Form) {
                'duplicate code' { $json.Replace('"code":', '"code":"AuthorizationFailed","code":') }
                'escaped duplicate code' { $json.Replace('"code":', '"\u0063ode":"AuthorizationFailed","code":') }
                'case-duplicate code' { $json.Replace('"code":', '"Code":"AuthorizationFailed","code":') }
                'trailing comma' { $json.Insert($json.Length - 1, ',') }
                'comment' { '/* unclassified */' + $json }
                'trailing data' { $json + ' Forbidden' }
            }
            $failure = [Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Safe summary.'), 'NativeFailure', 'InvalidResult', $null)
            $failure.ErrorDetails = [Management.Automation.ErrorDetails]::new($json)
            Test-AvmBicepRegionalValidationError -ErrorRecord $failure `
                -SubscriptionId $script:service.SubscriptionId -ResourceLocation eastus | Should -BeFalse
        }
    }

    It 'does not override HTTP or cancellation guards: <Boundary>' -ForEach @(
        @{ Boundary = '401'; Status = 401 }, @{ Boundary = '403'; Status = 403 }, @{ Boundary = '429'; Status = 429 }
        @{ Boundary = '500'; Status = 500 }, @{ Boundary = '504'; Status = 504 }, @{ Boundary = 'string status'; Status = '400' }
        @{ Boundary = 'array status'; Status = @(400) }, @{ Boundary = 'Boolean status'; Status = $true }
        @{ Boundary = 'cancellation'; Status = $null }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Boundary = $Boundary; Status = $Status } {
            param($Boundary, $Status)
            $exception = if ($Boundary -eq 'cancellation') {
                [InvalidOperationException]::new('Canceled.', [OperationCanceledException]::new())
            }
            else { [InvalidOperationException]::new('Service failure.') }
            if ($null -ne $Status) { $exception | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $Status } }
            $script:input.ErrorRecord = [Management.Automation.ErrorRecord]::new(
                $exception, 'AvmBicepTemplateValidationFailed', 'InvalidResult', $script:service.Response)
            Test-AvmBicepRegionalValidationError @script:input | Should -BeFalse
        }
    }
}

Describe 'Bicep service provider boundaries' {
    It 'keeps service identity evidence on its own sibling path' {
        $first = New-BicepServiceRetryFixture -Kind ContainerApps
        $second = New-BicepServiceRetryFixture -Kind ContainerAppsNewCluster
        $second.Response.error.target += '-second'
        InModuleScope Avm.Authoring -Parameters @{ First = $first; Second = $second } {
            param($First, $Second)
            $options = @{ ResourceLocation = 'eastus'; SubscriptionId = $First.SubscriptionId }
            foreach ($nodes in @(
                    @($First.Response, $Second.Response), @($Second.Response, $First.Response))) {
                Test-AvmBicepRetryErrorNode -Node $nodes @options | Should -BeTrue
            }
            foreach ($nodes in @(@($First.Response, $Second.Leaf), @($Second.Leaf, $First.Response))) {
                Test-AvmBicepRetryErrorNode -Node $nodes @options | Should -BeFalse
            }
        }
    }

    It 'does not infer a region from a MySQL resource ID or selected candidate' {
        InModuleScope Avm.Authoring {
            $node = @{
                code = 'ZoneNotAvailableForRegion'
                target = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/retry-fixture/providers/Microsoft.DBforMySQL/flexibleServers/server'
                message = 'The requested size for resource is currently not available in this zone. Please try another zone or deploy to a different location'
            }
            Test-AvmBicepRetryErrorNode -Node $node -ResourceLocation koreacentral `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' | Should -BeFalse
        }
    }

    It 'keeps untargeted Search evidence independent of subscription metadata: <Kind>' -ForEach @(
        @{ Kind = 'SearchSku' }, @{ Kind = 'SearchSemantic' }
    ) {
        $fixture = New-BicepServiceRetryFixture -Kind $Kind
        InModuleScope Avm.Authoring -Parameters @{ Node = $fixture.Response } {
            param($Node)
            Test-AvmBicepRetryErrorNode -Node $Node -ResourceLocation eastus | Should -BeTrue
        }
    }

    It 'does not generalize Search semantic messages or the official availability link: <Message>' -ForEach @(
        @{ Message = "Semantic Search is not available in 'eastus' region." }
        @{ Message = "Semantic Search is not available in 'eastus' region. Please refer to https://aka.ms/semanticsearchavailability-extra for list of available regions." }
        @{ Message = "Semantic Search is not available in 'eastus' region. Please refer to https://example.invalid/availability for list of available regions." }
        @{ Message = 'Access to Semantic Search is denied.' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Message = $Message } {
            param($Message)
            Test-AvmBicepRetryErrorNode -Node @{ code = 'BadRequest'; message = $Message } -ResourceLocation eastus | Should -BeFalse
        }
    }

    It 'requires the exact Search SKU and request ID diagnostic: <Change>' -ForEach @(
        @{ Change = 'missing request ID' }, @{ Change = 'invalid request ID' }, @{ Change = 'invalid SKU' }
        @{ Change = 'trailing newline' }
    ) {
        $fixture = New-BicepServiceRetryFixture -Kind SearchSku
        $fixture.Leaf.message = switch ($Change) {
            'missing request ID' { $fixture.Leaf.message -replace ' RequestId: .+$', '' }
            'invalid request ID' { $fixture.Leaf.message -replace 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'redacted' }
            'invalid SKU' { $fixture.Leaf.message.Replace("'standard'", "'standard or other'") }
            'trailing newline' { $fixture.Leaf.message + "`n" }
        }
        InModuleScope Avm.Authoring -Parameters @{ Node = $fixture.Response } {
            param($Node)
            Test-AvmBicepRetryErrorNode -Node $Node -ResourceLocation eastus | Should -BeFalse
        }
    }

    It 'accepts complete Container Apps diagnostics with Windows line endings' {
        foreach ($kind in @('ContainerApps', 'ContainerAppsNewCluster')) {
            $fixture = New-BicepServiceRetryFixture -Kind $kind
            $fixture.Leaf.message = $fixture.Leaf.message.Replace("`n", "`r`n")
            InModuleScope Avm.Authoring -Parameters @{ Node = $fixture.Response } {
                param($Node)
                Test-AvmBicepRetryErrorNode -Node $Node -ResourceLocation eastus `
                    -SubscriptionId '11111111-1111-1111-1111-111111111111' | Should -BeTrue
            }
        }
    }

    It 'requires complete Container Apps identity and embedded evidence: <Change>' -ForEach @(
        @{ Change = 'missing identity' }, @{ Change = 'wrong provider' }, @{ Change = 'body permission code' }
        @{ Change = 'duplicate body code' }, @{ Change = 'escaped duplicate body code' }, @{ Change = 'case-duplicate body code' }
        @{ Change = 'mixed body details' }, @{ Change = 'unknown body field' }, @{ Change = 'body key casing' }
        @{ Change = 'body region mismatch' }, @{ Change = 'malformed body' }, @{ Change = 'body trailing comma' }
        @{ Change = 'nonempty subcode' }, @{ Change = 'HTTP 403' }, @{ Change = 'wrong error code' }
        @{ Change = 'missing capacity link' }, @{ Change = 'missing region link' }, @{ Change = 'trailing line' }
        @{ Change = 'duplicate header' }, @{ Change = 'case-duplicate header' }, @{ Change = 'unknown header' }
        @{ Change = 'malformed header' }, @{ Change = 'missing headers' }, @{ Change = 'body comment' }
        @{ Change = 'missing body field' }, @{ Change = 'whitespace header' }
    ) {
        foreach ($kind in @('ContainerApps', 'ContainerAppsNewCluster')) {
            $fixture = New-BicepServiceRetryFixture -Kind $kind
            $leaf = $fixture.Leaf
            switch ($Change) {
                'missing identity' { $fixture.Response.error.Remove('target') }
                'wrong provider' { $fixture.Response.error.target = $fixture.ResourceId.Replace($fixture.Provider, 'Microsoft.ContainerService/managedClusters') }
                'body permission code' { $leaf.message = $leaf.message.Replace('"code":"AKSCapacityHeavyUsage"', '"code":"AuthorizationFailed"') }
                'duplicate body code' { $leaf.message = $leaf.message.Replace('"code":', '"code":"AuthorizationFailed","code":') }
                'escaped duplicate body code' { $leaf.message = $leaf.message.Replace('"code":', '"\u0063ode":"AuthorizationFailed","code":') }
                'case-duplicate body code' { $leaf.message = $leaf.message.Replace('"code":', '"Code":"AuthorizationFailed","code":') }
                'mixed body details' { $leaf.message = $leaf.message.Replace('"details":null', '"details":[{"code":"AuthorizationFailed"}]') }
                'unknown body field' { $leaf.message = $leaf.message.Replace('"details":null', '"details":null,"unknown":null') }
                'body key casing' { $leaf.message = $leaf.message.Replace('"details":null', '"Details":null') }
                'body region mismatch' { $leaf.message = $leaf.message -creplace '("message":"[^"]*region )eastus', '${1}westus2' }
                'malformed body' { $leaf.message = $leaf.message.Replace('"subcode":""', '"subcode":') }
                'body trailing comma' { $leaf.message = $leaf.message.Replace('"subcode":""}', '"subcode":"",}') }
                'body comment' { $leaf.message = $leaf.message.Replace('"details":null', '"details":/* unknown */null') }
                'missing body field' { $leaf.message = $leaf.message.Replace(',"subcode":""', '') }
                'nonempty subcode' { $leaf.message = $leaf.message.Replace('"subcode":""', '"subcode":"PermissionDenied"') }
                'HTTP 403' { $leaf.message = $leaf.message.Replace('400 (Bad Request)', '403 (Forbidden)') }
                'wrong error code' { $leaf.message = $leaf.message.Replace('ErrorCode: AKSCapacityHeavyUsage', 'ErrorCode: Forbidden') }
                'missing capacity link' { $leaf.message = $leaf.message.Replace('https://aka.ms/akscapacityheavyusage', 'https://example.invalid/capacity') }
                'missing region link' { $leaf.message = $leaf.message.Replace('https://aka.ms/aks/regions', 'https://example.invalid/regions') }
                'trailing line' { $leaf.message += "AuthorizationFailed`n" }
                'duplicate header' { $leaf.message += "Content-Type: text/plain`n" }
                'case-duplicate header' { $leaf.message += "content-type: text/plain`n" }
                'unknown header' { $leaf.message += "Unclassified: permission failure`n" }
                'malformed header' { $leaf.message += "Date: `n" }
                'whitespace header' { $leaf.message += "Date:  `n" }
                'missing headers' { $leaf.message = $leaf.message.Replace("Content-Type: application/json`n", '') }
            }
            InModuleScope Avm.Authoring -Parameters @{ Node = $fixture.Response } {
                param($Node)
                Test-AvmBicepRetryErrorNode -Node $Node -ResourceLocation eastus `
                    -SubscriptionId '11111111-1111-1111-1111-111111111111' | Should -BeFalse
            }
        }
    }
}
