#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        foreach ($name in @('Invoke-AzRestMethod', 'Get-AzKeyVault', 'Get-AzCognitiveServicesAccount', 'Set-AzContext')) {
            Set-Item -Path "Function:script:$name" -Value {
                [CmdletBinding()]
                param($Method, $Path, $Name, $SubscriptionId, [switch] $InRemovedState)
                throw "Unexpected Azure call: $($MyInvocation.MyCommand.Name)"
            }
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep REST response validation diagnostics' {
    It 'reports only a recognized code and named GUID headers for HTTP <Status>' -ForEach @(
        @{ Status = 403 }, @{ Status = 429 }, @{ Status = 500 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Status = $Status } {
            param($Status)
            $http = [System.Net.Http.HttpResponseMessage]::new()
            $null = $http.Headers.TryAddWithoutValidation('x-ms-request-id', '11111111-2222-3333-4444-555555555555')
            $null = $http.Headers.TryAddWithoutValidation('x-ms-correlation-request-id', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
            $null = $http.Headers.TryAddWithoutValidation('Authorization', 'Bearer header-secret')
            $response = @{
                StatusCode = [System.Net.HttpStatusCode]$Status
                Content = '{"error":{"code":"AuthorizationFailed","message":"body-secret"}}'
                Headers = $http.Headers
            }
            $failure = $null
            try { ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Read cleanup operation page' }
            catch { $failure = $_ }
            $failure.Exception | Should -BeOfType ([AvmProcessException])
            $failure.Exception.Message | Should -Match "status=HTTP $Status"
            $failure.Exception.Message | Should -Match 'response=object.*content=string.*code=AuthorizationFailed'
            $failure.Exception.Message | Should -Match 'x-ms-request-id=11111111-2222-3333-4444-555555555555'
            $failure.Exception.Message | Should -Match 'x-ms-correlation-request-id=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $failure.Exception.Message | Should -Not -Match 'body-secret|header-secret|Bearer|Authorization:'
            $http.Dispose()
        }
    }

    It 'keeps invalid response and status shapes explicit without converting their values: <Shape>' -ForEach @(
        @{ Shape = 'null response'; Response = $null; Expected = 'response=null; status=missing; content=missing' }
        @{ Shape = 'array response'; Response = @(1, 2); Expected = 'response=array; status=missing; content=missing' }
        @{ Shape = 'string status'; Response = @{ StatusCode = 'secret-status'; Content = '{}' }; Expected = 'status=string' }
        @{ Shape = 'array status'; Response = @{ StatusCode = @(403); Content = '{}' }; Expected = 'status=array' }
        @{ Shape = 'boolean status'; Response = @{ StatusCode = $true; Content = '{}' }; Expected = 'status=other' }
        @{ Shape = 'out-of-range status'; Response = @{ StatusCode = 9999; Content = '{}' }; Expected = 'status=out-of-range integer' }
        @{ Shape = 'array content'; Response = @{ StatusCode = 200; Content = @('secret-content') }; Expected = 'content=array' }
        @{ Shape = 'object content'; Response = @{ StatusCode = 200; Content = @{ secret = 'secret-content' } }; Expected = 'content=object' }
        @{ Shape = 'scalar content'; Response = @{ StatusCode = 200; Content = $true }; Expected = 'content=scalar' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Response = $Response; Expected = $Expected } {
            param($Response, $Expected)
            $failure = $null
            try { ConvertFrom-AvmBicepRestResponse -Response $Response -Activity 'Read cleanup operation page' }
            catch { $failure = $_ }
            $failure.Exception | Should -BeOfType ([AvmProcessException])
            $failure.Exception.Message | Should -BeLike "*$Expected*"
            $failure.Exception.Message | Should -Not -Match 'secret|9999'
        }
    }

    It 'omits malformed or untrusted code and header values: <Case>' -ForEach @(
        @{ Case = 'unrecognized identifier'; Body = '{"error":{"code":"secretTokenValue"}}'; Header = 'secretTokenValue' }
        @{ Case = 'message as code'; Body = '{"error":{"code":"secret text\ninjected"}}'; Header = "11111111-2222-3333-4444-555555555555`nsecret" }
        @{ Case = 'duplicate code'; Body = '{"error":{"code":"AuthorizationFailed","Code":"secret"}}'; Header = @('11111111-2222-3333-4444-555555555555', 'secret') }
        @{ Case = 'object code'; Body = '{"error":{"code":{"value":"secret"}}}'; Header = @{ value = 'secret' } }
        @{ Case = 'invalid JSON'; Body = '{"error":"secret"'; Header = 'secret' }
        @{ Case = 'oversized body'; Body = ('secret' * 11000); Header = 'secret' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Body = $Body; Header = $Header } {
            param($Body, $Header)
            $response = @{
                StatusCode = 403
                Content = $Body
                Headers = @{ 'x-ms-request-id' = $Header; 'other-header' = 'secret-other' }
            }
            $failure = $null
            try { ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Read cleanup operation page' }
            catch { $failure = $_ }
            $failure.Exception | Should -BeOfType ([AvmProcessException])
            $failure.Exception.Message | Should -Match 'status=HTTP 403'
            $failure.Exception.Message | Should -Not -Match 'secret|AuthorizationFailed|x-ms-request-id='
        }
    }

    It 'does not change accepted responses or JSON failure categories' {
        InModuleScope Avm.Authoring {
            (ConvertFrom-AvmBicepRestResponse -Response @{ StatusCode = 200; Content = '{"value":[]}' } `
                -Activity 'Read' -AllowedStatus @(200, 404))['value'].Count | Should -Be 0
            (ConvertFrom-AvmBicepRestResponse -Response @{
                    StatusCode = [System.Net.HttpStatusCode]::NotFound
                    Content = '{"error":{"code":"DeploymentNotFound"}}'
                } -Activity 'Read' -AllowedStatus @(200, 404))['error']['code'] | Should -BeExactly 'DeploymentNotFound'
            { ConvertFrom-AvmBicepRestResponse -Response @{ StatusCode = 200; Content = '{"secret"' } -Activity 'Read' } |
                Should -Throw '*returned invalid JSON*'
            { ConvertFrom-AvmBicepRestResponse -Response @{ StatusCode = 200; Content = '[]' } -Activity 'Read' } |
                Should -Throw '*returned invalid JSON*'
        }
    }

    It 'retains the original failure category when an optional header cannot be read' {
        InModuleScope Avm.Authoring {
            $response = [pscustomobject]@{ StatusCode = 403; Content = '{}' }
            $response | Add-Member -MemberType ScriptProperty -Name Headers -Value { throw 'header-secret' }
            $failure = $null
            try { ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Read cleanup operation page' }
            catch { $failure = $_ }
            $failure.Exception | Should -BeOfType ([AvmProcessException])
            $failure.Exception.Message | Should -Match 'invalid response or HTTP status.*status=HTTP 403'
            $failure.Exception.Message | Should -Not -Match 'header-secret'
        }
    }
}

Describe 'Bicep relocation regional classification' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:root = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/root'
            $script:regional = @{ code = 'SkuNotAvailable'; message = 'The requested size is not available in location eastus.' }
            $script:pages = @{}
            Mock Invoke-AzRestMethod {
                param($Method, $Path)
                if (-not $script:pages.ContainsKey($Path)) { throw "Unexpected path $Path" }
                [pscustomobject]@{ StatusCode = 200; Content = $script:pages[$Path] | ConvertTo-Json -Depth 20 }
            }
            $script:respond = {
                param($State, [object[]] $Operations)
                $script:pages[$script:root + '?api-version=2021-04-01'] = @{ id = $script:root; properties = @{ provisioningState = $State } }
                $script:pages[$script:root + '/operations?api-version=2025-04-01'] = @{ value = $Operations }
            }
            $script:failed = {
                param($ErrorNode)
                @{ properties = @{ provisioningOperation = 'Create'; provisioningState = 'Failed'; statusMessage = @{ error = $ErrorNode } } }
            }
        }
    }

    It 'relocates only when every failed operation is regional, including wrapped failures' {
        InModuleScope Avm.Authoring {
            & $script:respond 'Failed' @(
                @{ properties = @{ provisioningOperation = 'Read'; provisioningState = 'Succeeded' } }
                & $script:failed $script:regional
                & $script:failed @{ code = 'ResourceDeploymentFailure'; message = 'wrapped'; details = @($script:regional) }
            )
            Get-AvmBicepDeploymentRetryKind -DeploymentId $script:root | Should -BeExactly 'Regional'
        }
    }

    It 'stays in place when any failure is not regional or has no structured error' -ForEach @(
        @{ Label = 'a quota error'; Node = @{ code = 'QuotaExceeded'; message = 'Quota exceeded in region eastus.' } }
        @{ Label = 'an empty wrapper'; Node = @{ code = 'ResourceDeploymentFailure'; message = 'wrapped' } }
        @{ Label = 'a string error'; Node = 'capacity in region' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Node = $Node } {
            param($Node)
            & $script:respond 'Failed' @((& $script:failed $script:regional), (& $script:failed $Node))
            Get-AvmBicepDeploymentRetryKind -DeploymentId $script:root | Should -BeExactly 'None'
        }
    }

    It 'does not read operations unless the deployment is exactly Failed' {
        InModuleScope Avm.Authoring {
            & $script:respond 'Canceled' @()
            Get-AvmBicepDeploymentRetryKind -DeploymentId $script:root | Should -BeExactly 'None'
            Should -Invoke Invoke-AzRestMethod -Exactly 1
        }
    }

    It 'retries only a timed-out <Read> without rereading completed pages' -ForEach @(
        @{ Read = 'root' }, @{ Read = 'first page' }, @{ Read = 'second page' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Read = $Read } {
            param($Read)
            & $script:respond 'Failed' @((& $script:failed $script:regional))
            $script:rootPath = $script:root + '?api-version=2021-04-01'
            $script:firstPage = $script:root + '/operations?api-version=2025-04-01'
            $script:secondPage = $script:firstPage + '&page=2'
            $script:pages[$script:firstPage].nextLink = $script:secondPage
            $script:pages[$script:secondPage] = @{ value = @((& $script:failed $script:regional)) }
            $script:timeoutPath = switch ($Read) {
                'root' { $script:rootPath }
                'first page' { $script:firstPage }
                'second page' { $script:secondPage }
            }
            $script:readCounts = @{}
            Mock Wait-AvmRetryDelay {}
            Mock Invoke-AzRestMethod {
                $script:readCounts[$Path] = 1 + [int]$script:readCounts[$Path]
                if ($Path -ceq $script:timeoutPath -and $script:readCounts[$Path] -eq 1) {
                    @{ StatusCode = 200; Content = '{"error":{"code":"partial-invalid-output"}}' }
                    throw [TimeoutException]::new('Read timed out.')
                }
                @{ StatusCode = 200; Content = $script:pages[$Path] | ConvertTo-Json -Depth 20 -Compress }
            }
            Get-AvmBicepDeploymentRetryKind -DeploymentId $script:root | Should -BeExactly 'Regional'
            foreach ($path in @($script:rootPath, $script:firstPage, $script:secondPage)) {
                $expected = if ($path -ceq $script:timeoutPath) { 2 } else { 1 }
                $script:readCounts[$path] | Should -Be $expected
            }
            Should -Invoke Wait-AvmRetryDelay -Exactly 1
            Should -Invoke Invoke-AzRestMethod -Exactly 0 -ParameterFilter { $Method -cne 'GET' }
        }
    }

    It 'rejects singleton arrays where structured properties are required: <Field>' -ForEach @(
        @{ Field = 'root properties' }, @{ Field = 'operation properties' }, @{ Field = 'status message' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Field = $Field } {
            param($Field)
            & $script:respond 'Failed' @((& $script:failed $script:regional))
            $page = $script:pages[$script:root + '/operations?api-version=2025-04-01']
            switch ($Field) {
                'root properties' {
                    $root = $script:pages[$script:root + '?api-version=2021-04-01']
                    $root.properties = @($root.properties)
                }
                'operation properties' { $page.value[0].properties = @($page.value[0].properties) }
                'status message' { $page.value[0].properties.statusMessage = @($page.value[0].properties.statusMessage) }
            }
            Get-AvmBicepDeploymentRetryKind -DeploymentId $script:root | Should -BeExactly 'None'
        }
    }

    It 'rejects operation pages containing success data and <Extra> simultaneously' -ForEach @(
        @{ Extra = 'error' }, @{ Extra = 'unknown' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Extra = $Extra } {
            param($Extra)
            & $script:respond 'Failed' @((& $script:failed $script:regional))
            $script:pages[$script:root + '/operations?api-version=2025-04-01'][$Extra] = @{ code = 'AuthorizationFailed' }
            { Get-AvmBicepDeploymentRetryKind -DeploymentId $script:root } | Should -Throw
        }
    }

    It 'rejects ambiguous raw JSON on the second operation page: <Form>' -ForEach @(
        @{ Form = 'duplicate code' }, @{ Form = 'escaped duplicate code' }, @{ Form = 'case-duplicate code' }
        @{ Form = 'comment' }, @{ Form = 'trailing comma' }, @{ Form = 'array envelope' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Form = $Form } {
            param($Form)
            & $script:respond 'Failed' @((& $script:failed $script:regional))
            $script:firstPage = $script:root + '/operations?api-version=2025-04-01'
            $script:nextPage = $script:firstPage + '&page=2'
            $script:pages[$script:firstPage].nextLink = $script:nextPage
            $json = @{ value = @((& $script:failed $script:regional)) } | ConvertTo-Json -Depth 20 -Compress
            $script:invalidPage = switch ($Form) {
                'duplicate code' { $json.Replace('"code":', '"code":"AuthorizationFailed","code":') }
                'escaped duplicate code' { $json.Replace('"code":', '"\u0063ode":"AuthorizationFailed","code":') }
                'case-duplicate code' { $json.Replace('"code":', '"Code":"AuthorizationFailed","code":') }
                'comment' { '/* unclassified */' + $json }
                'trailing comma' { $json.Insert($json.Length - 1, ',') }
                'array envelope' { '[' + $json + ']' }
            }
            Mock Invoke-AzRestMethod {
                $content = if ($Path -eq $script:nextPage) { $script:invalidPage }
                else { $script:pages[$Path] | ConvertTo-Json -Depth 20 }
                @{ StatusCode = 200; Content = $content }
            }
            { Get-AvmBicepDeploymentRetryKind -DeploymentId $script:root } | Should -Throw
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter { $Path -eq $script:firstPage }
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter { $Path -eq $script:nextPage }
        }
    }

    It 'rejects untyped HTTP evidence for both the deployment and operation pages: <Kind>' -ForEach @(
        @{ Kind = 'Boolean'; HttpStatus = $true }
        @{ Kind = 'string'; HttpStatus = '200' }
        @{ Kind = 'floating point'; HttpStatus = 200.1 }
        @{ Kind = 'singleton array'; HttpStatus = @(200) }
        @{ Kind = 'missing'; HttpStatus = $null }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ HttpStatus = $HttpStatus } {
            param($HttpStatus)
            & $script:respond 'Failed' @((& $script:failed $script:regional))
            $script:invalidStatus = $HttpStatus
            $script:invalidResponsePath = $script:root + '?api-version=2021-04-01'
            Mock Invoke-AzRestMethod {
                param($Path)
                $response = [pscustomobject]@{
                    StatusCode = 200
                    Content = $script:pages[$Path] | ConvertTo-Json -Depth 20
                }
                if ($Path -eq $script:invalidResponsePath) { $response.StatusCode = $script:invalidStatus }
                return $response
            }
            { Get-AvmBicepDeploymentRetryKind -DeploymentId $script:root } |
                Should -Throw '*invalid response or HTTP status*'
            $script:invalidResponsePath = $script:root + '/operations?api-version=2025-04-01'
            { Get-AvmBicepDeploymentRetryKind -DeploymentId $script:root } |
                Should -Throw '*invalid response or HTTP status*'
        }
    }
}

Describe 'Bicep strict relocation discovery' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:root = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/root'
            $script:nested = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/nested'
            $script:group = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'
            $script:pages = @{}
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
            Mock Invoke-AzRestMethod {
                param($Method, $Path)
                if (-not $script:pages.ContainsKey($Path)) { throw "Unexpected path $Path" }
                $page = $script:pages[$Path]
                [pscustomobject]@{ StatusCode = $page.Status; Content = $page.Body | ConvertTo-Json -Depth 20 }
            }
            $script:set = {
                param($Id, $State, [object[]] $Operations)
                $script:pages[$Id + '?api-version=2021-04-01'] = @{
                    Status = 200; Body = @{ id = $Id; properties = @{ provisioningState = $State } }
                }
                $script:pages[$Id + '/operations?api-version=2025-04-01'] = @{ Status = 200; Body = @{ value = $Operations } }
            }
            $script:create = {
                param($Id, $State = 'Succeeded')
                @{ properties = @{ provisioningOperation = 'Create'; provisioningState = $State; targetResource = @{ id = $Id } } }
            }
        }
    }

    It 'accepts a failed root with finished nested work' {
        InModuleScope Avm.Authoring {
            & $script:set $script:root 'Failed' @((& $script:create $script:group), (& $script:create $script:nested 'Failed'))
            & $script:set $script:nested 'Succeeded' @()
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) -RequireCompleteRemoval
            $result.Issues.Count | Should -Be 0
            $result.ResourceIds | Should -Be @($script:group)
            ($result.Deployments | Where-Object Id -EQ $script:nested).Depth | Should -Be 1
        }
    }

    It 'refuses <Label>' -ForEach @(
        @{ Label = 'a root that is still running'; RootState = 'Running'; OperationState = 'Succeeded'; Target = $true }
        @{ Label = 'a succeeded root'; RootState = 'Succeeded'; OperationState = 'Succeeded'; Target = $true }
        @{ Label = 'an unfinished operation'; RootState = 'Failed'; OperationState = 'Running'; Target = $true }
        @{ Label = 'a created operation without a target'; RootState = 'Failed'; OperationState = 'Failed'; Target = $false }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ RootState = $RootState; OperationState = $OperationState; Target = $Target } {
            param($RootState, $OperationState, $Target)
            $operation = & $script:create $script:group $OperationState
            if (-not $Target) { $operation.properties.Remove('targetResource') }
            & $script:set $script:root $RootState @($operation)
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) -RequireCompleteRemoval
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].Code | Should -BeExactly 'LookupFailed'
        }
    }

    It 'treats an absent nested record as unresolved only in strict mode' {
        InModuleScope Avm.Authoring {
            & $script:set $script:root 'Failed' @(& $script:create $script:nested 'Failed')
            $script:pages[$script:nested + '?api-version=2021-04-01'] = @{
                Status = 404; Body = @{ error = @{ code = 'DeploymentNotFound' } }
            }
            $script:pages[$script:nested + '/operations?api-version=2025-04-01'] = $script:pages[$script:nested + '?api-version=2021-04-01']
            (Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root)).Issues.Count | Should -Be 0
            $strict = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) -RequireCompleteRemoval
            $strict.Issues.Count | Should -Be 1
            $strict.Issues[0].DeploymentId | Should -BeExactly $script:nested
        }
    }
}

Describe 'Bicep deployment record removal' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:group = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'
            $script:root = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/root'
            $script:inGroup = "$script:group/providers/Microsoft.Resources/deployments/child"
            $script:deleted = [System.Collections.Generic.List[string]]::new()
            Mock Start-Sleep {}
            Mock Invoke-AzRestMethod {
                param($Method, $Path)
                if ($Method -eq 'DELETE') {
                    $script:deleted.Add($Path)
                    return [pscustomobject]@{ StatusCode = 202; Content = '' }
                }
                [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}' }
            }
        }
    }

    It 'skips records inside a removed parent and confirms each deletion' {
        InModuleScope Avm.Authoring {
            Remove-AvmBicepDeploymentRecord -DeploymentIds @($script:inGroup, $script:root) `
                -RemovedParentIds @($script:group) -RetryInterval 0
            $script:deleted | Should -Be @($script:root + '?api-version=2021-04-01')
            Should -Invoke Invoke-AzRestMethod -Exactly 2
        }
    }

    It 'fails when <Label>' -ForEach @(
        @{ Label = 'the record remains after every lookup'; Status = 200; Content = 'present'; Message = '*still exists*' }
        @{ Label = 'a 404 has an unexpected code'; Status = 404; Content = '{"error":{"code":"AuthorizationFailed"}}'; Message = '*not confirmed*' }
        @{ Label = 'the lookup fails'; Status = 500; Content = '{}'; Message = '*HTTP 500*' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Status = $Status; Content = $Content; Message = $Message } {
            param($Status, $Content, $Message)
            if ($Content -eq 'present') {
                $Content = @{ id = $script:root; properties = @{ provisioningState = 'Failed' } } | ConvertTo-Json
            }
            $script:lookup = [pscustomobject]@{ StatusCode = $Status; Content = $Content }
            Mock Invoke-AzRestMethod {
                param($Method)
                if ($Method -eq 'DELETE') { return [pscustomobject]@{ StatusCode = 202; Content = '' } }
                $script:lookup
            }
            { Remove-AvmBicepDeploymentRecord -DeploymentIds @($script:root) -RetryLimit 2 -RetryInterval 0 } |
                Should -Throw -ExpectedMessage $Message
        }
    }

    It 'never deletes in WhatIf mode' {
        InModuleScope Avm.Authoring {
            { Remove-AvmBicepDeploymentRecord -DeploymentIds @($script:root) -WhatIf } | Should -Throw '*not performed*'
            Should -Invoke Invoke-AzRestMethod -Exactly 0
        }
    }
}

Describe 'Bicep soft-deleted name reservations' {
    It 'reports a removed key vault with the same resource ID' {
        InModuleScope Avm.Authoring {
            $id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.KeyVault/vaults/kv'
            $script:vaultId = $id
            Mock Get-AzKeyVault { [pscustomobject]@{ ResourceId = $script:vaultId } }
            Test-AvmBicepSoftDeletedResource -ResourceId $id -Type 'Microsoft.KeyVault/vaults' | Should -BeTrue
            Test-AvmBicepSoftDeletedResource -ResourceId ($id + '2') -Type 'Microsoft.KeyVault/vaults' | Should -BeFalse
        }
    }

    It 'does not look up types without soft deletion' {
        InModuleScope Avm.Authoring {
            Mock Get-AzKeyVault { throw 'unexpected' }
            Test-AvmBicepSoftDeletedResource -ResourceId '/subscriptions/x/resourceGroups/test/providers/Microsoft.Network/virtualNetworks/net' `
                -Type 'Microsoft.Network/virtualNetworks' | Should -BeFalse
        }
    }
}