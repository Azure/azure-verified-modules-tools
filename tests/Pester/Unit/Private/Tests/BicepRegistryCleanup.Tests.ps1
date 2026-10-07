#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:Invoke-AzRestMethod {
            [CmdletBinding()]
            param($Method, $Path)
            throw "Unexpected Azure call: $Method $Path"
        }
    }
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep registry cleanup proof' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:root = '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Resources/deployments/root'
            $script:child = $script:root.Replace('/root', '/child')
            $script:group = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/test'
            $script:responses = @{}
            $script:requests = [System.Collections.Generic.List[string]]::new()
            Mock Start-Sleep {}
            Mock Write-AvmLog {}
            Mock Invoke-AzRestMethod {
                param($Method, $Path)
                $script:requests.Add("$Method $Path")
                if (-not $script:responses.ContainsKey("$Method $Path")) { throw "Unexpected Azure request: $Method $Path" }
                $script:responses["$Method $Path"]
            }
            $script:record = {
                param($Id, $State, [object[]] $Operations)
                $script:responses["GET $Id`?api-version=2021-04-01"] = @{
                    StatusCode = 200; Content = @{ id = $Id; properties = @{ provisioningState = $State } } | ConvertTo-Json
                }
                $script:responses["GET $Id/operations?api-version=2021-04-01"] = @{
                    StatusCode = 200; Content = @{ value = $Operations } | ConvertTo-Json -Depth 30 -Compress
                }
            }
            $script:sibling = @{
                properties = @{ provisioningOperation = 'Create'; provisioningState = 'Succeeded'; targetResource = @{ id = $script:group } }
            }
            $script:preflight = @{
                properties = @{
                    provisioningOperation = 'Create'; provisioningState = 'Failed'; statusCode = 'BadRequest'
                    targetResource = @{ id = $script:child; resourceType = 'Microsoft.Resources/deployments'; resourceName = 'child' }
                    statusMessage = @{
                        status = 'Failed'
                        error = @{
                            code = 'InvalidTemplateDeployment'; target = $script:child
                            message = "The template deployment 'child' is not valid according to the validation procedure. Resource reported preflight validation errors."
                            details = @(@{ code = 'AllocationFailed'; message = 'No capacity in this region.' })
                        }
                    }
                }
            }
            $script:graph = @{
                properties = @{
                    provisioningOperation = 'Create'; provisioningState = 'Succeeded'
                    targetResource = @{
                        resourceType = 'Microsoft.Graph/servicePrincipals@v1.0'; symbolicName = 'principal'
                        extension = @{ name = 'MicrosoftGraph'; version = '1.0.0'; alias = 'graph' }
                    }
                }
            }
            $script:export = @{
                template = @{
                    '$schema' = 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
                    languageVersion = '2.0'
                    resources = @{ principal = @{ existing = $true; type = 'Microsoft.Graph/servicePrincipals@v1.0'; import = 'graph' } }
                    imports = @{ graph = @{ provider = 'MicrosoftGraph'; version = '1.0.0' } }
                }
            }
            $script:responses["GET $script:child`?api-version=2021-04-01"] = @{
                StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}'
            }
        }
    }

    It 'omits a unique preflight-rejected child only after exact record absence and keeps successful siblings' {
        InModuleScope Avm.Authoring {
            & $script:record $script:root 'Failed' @($script:sibling, $script:preflight)
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) -RequireCompleteRemoval
            $result.Issues.Count | Should -Be 0
            $result.ResourceIds | Should -Be @($script:group)
            ($result.Deployments | Where-Object Id -EQ $script:child).Status | Should -Be 'RejectedWithoutRecord'
            $script:requests | Should -Contain "GET $script:child`?api-version=2021-04-01"
            $script:requests | Should -Not -Contain "GET $script:child/operations?api-version=2021-04-01"
        }
    }

    It 'does not accept ambiguous or incomplete child absence: <Mutation>' -ForEach @(
        @{ Mutation = 'duplicate operation' }, @{ Mutation = 'wrong name' }, @{ Mutation = 'wrong type' }
        @{ Mutation = 'wrong error target' }, @{ Mutation = 'wrong absence target' }, @{ Mutation = 'array error code' }
        @{ Mutation = 'missing details' }, @{ Mutation = 'string status' }, @{ Mutation = 'operation succeeded' }
        @{ Mutation = 'container absent' }, @{ Mutation = 'existing record missing operations' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mutation = $Mutation } {
            param($Mutation)
            $operations = @($script:sibling, $script:preflight)
            switch ($Mutation) {
                'duplicate operation' { $operations += $script:preflight }
                'wrong name' { $script:preflight.properties.targetResource.resourceName = 'another' }
                'wrong type' { $script:preflight.properties.targetResource.resourceType = 'Microsoft.Resources/other' }
                'wrong error target' { $script:preflight.properties.statusMessage.error.target += '-other' }
                'wrong absence target' {
                    $script:responses["GET $script:child`?api-version=2021-04-01"].Content =
                        '{"error":{"code":"DeploymentNotFound","target":"/another/deployment"}}'
                }
                'array error code' { $script:preflight.properties.statusMessage.error.code = @('InvalidTemplateDeployment') }
                'missing details' { $script:preflight.properties.statusMessage.error.Remove('details') }
                'string status' { $script:preflight.properties.statusMessage = 'Failed' }
                'operation succeeded' { $script:preflight.properties.provisioningState = 'Succeeded' }
                'container absent' {
                    $script:responses["GET $script:child`?api-version=2021-04-01"].Content = '{"error":{"code":"ResourceGroupNotFound"}}'
                }
                'existing record missing operations' {
                    & $script:record $script:child 'Failed' @()
                    $script:responses["GET $script:child/operations?api-version=2021-04-01"] = @{
                        StatusCode = 404; Content = '{"error":{"code":"DeploymentNotFound"}}'
                    }
                }
            }
            & $script:record $script:root 'Failed' $operations
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) -RequireCompleteRemoval
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].DeploymentId | Should -BeExactly $script:child
            $result.ResourceIds | Should -Be @($script:group)
        }
    }

    It 'still discovers a preflight-marked child whose record exists' {
        InModuleScope Avm.Authoring {
            & $script:record $script:root 'Failed' @($script:preflight)
            & $script:record $script:child 'Succeeded' @($script:sibling)
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) -RequireCompleteRemoval
            $result.Issues.Count | Should -Be 0
            $result.ResourceIds | Should -Be @($script:group)
            ($result.Deployments | Where-Object Id -EQ $script:child).Status | Should -Be 'Resolved'
        }
    }

    It 'checks all pages before deciding whether a preflight operation is unique' {
        InModuleScope Avm.Authoring {
            & $script:record $script:root 'Failed' @($script:sibling, $script:preflight)
            $pageTwo = "$script:root/operations?api-version=2021-04-01&next=2"
            $script:responses["GET $script:root/operations?api-version=2021-04-01"].Content = @{
                value = @($script:sibling, $script:preflight); nextLink = $pageTwo
            } | ConvertTo-Json -Depth 30
            $script:responses["GET $pageTwo"] = @{
                StatusCode = 200; Content = @{ value = @($script:preflight) } | ConvertTo-Json -Depth 30
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) -RequireCompleteRemoval
            $result.Issues.Count | Should -Be 1
            $script:requests | Should -Contain "GET $pageTwo"
        }
    }

    It 'proves ID-less existing Graph lookups using one exact export in <Mode> cleanup' -ForEach @(
        @{ Mode = 'strict'; Strict = $true }, @{ Mode = 'ordinary'; Strict = $false }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Strict = $Strict } {
            param($Strict)
            & $script:record $script:root 'Failed' @($script:sibling, $script:graph, $script:graph)
            $script:responses["POST $script:root/exportTemplate?api-version=2025-04-01"] = @{
                StatusCode = 200; Content = $script:export | ConvertTo-Json -Depth 30
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) -RequireCompleteRemoval:$Strict
            $result.Issues.Count | Should -Be 0
            $result.ResourceIds | Should -Be @($script:group)
            @($script:requests | Where-Object { $_ -like 'POST *' }).Count | Should -Be 1
        }
    }

    It 'refuses unproven Graph operations while retaining known targets: <Mutation>' -ForEach @(
        @{ Mutation = 'not existing' }, @{ Mutation = 'string existing' }, @{ Mutation = 'missing declaration' }
        @{ Mutation = 'wrong type' }, @{ Mutation = 'wrong import' }, @{ Mutation = 'wrong provider' }
        @{ Mutation = 'wrong version' }, @{ Mutation = 'wrong scope' }, @{ Mutation = 'wrong language' }
        @{ Mutation = 'ID property present' }, @{ Mutation = 'status message' }, @{ Mutation = 'export denied' }
        @{ Mutation = 'error envelope' }, @{ Mutation = 'duplicate symbol' }, @{ Mutation = 'case-duplicate alias' }
        @{ Mutation = 'Boolean HTTP status' }, @{ Mutation = 'array HTTP status' }, @{ Mutation = 'string HTTP status' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mutation = $Mutation } {
            param($Mutation)
            switch ($Mutation) {
                'not existing' { $script:export.template.resources.principal.existing = $false }
                'string existing' { $script:export.template.resources.principal.existing = 'true' }
                'missing declaration' { $script:export.template.resources.Clear() }
                'wrong type' { $script:export.template.resources.principal.type = 'Microsoft.Graph/applications@v1.0' }
                'wrong import' { $script:export.template.resources.principal.import = 'other' }
                'wrong provider' { $script:export.template.imports.graph.provider = 'AnotherProvider' }
                'wrong version' { $script:export.template.imports.graph.version = '2.0.0' }
                'wrong scope' { $script:export.template['$schema'] = $script:export.template['$schema'].Replace('subscriptionDeploymentTemplate', 'tenantDeploymentTemplate') }
                'wrong language' { $script:export.template.languageVersion = '1.0' }
                'ID property present' { $script:graph.properties.targetResource.id = $null }
                'status message' { $script:graph.properties.statusMessage = @{} }
                'error envelope' { $script:export.error = @{ code = 'AuthorizationFailed' } }
            }
            & $script:record $script:root 'Failed' @($script:sibling, $script:graph)
            $json = $script:export | ConvertTo-Json -Depth 30 -Compress
            if ($Mutation -eq 'duplicate symbol') { $json = $json.Replace('"principal":', '"principal":{},"principal":') }
            if ($Mutation -eq 'case-duplicate alias') { $json = $json.Replace('"graph":', '"GRAPH":{},"graph":') }
            $script:responses["POST $script:root/exportTemplate?api-version=2025-04-01"] = @{
                StatusCode = switch ($Mutation) {
                    'export denied' { 403 }
                    'Boolean HTTP status' { $true }
                    'array HTTP status' { , @(200) }
                    'string HTTP status' { '200' }
                    default { 200 }
                }
                Content = $json
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) -RequireCompleteRemoval
            $result.Issues.Count | Should -Be 1
            $result.ResourceIds | Should -Be @($script:group)
        }
    }

    It 'does not reuse parent Graph proof for a nested deployment' {
        InModuleScope Avm.Authoring {
            & $script:record $script:root 'Failed' @($script:graph, $script:preflight)
            & $script:record $script:child 'Failed' @($script:graph)
            $script:responses["POST $script:root/exportTemplate?api-version=2025-04-01"] = @{
                StatusCode = 200; Content = $script:export | ConvertTo-Json -Depth 30
            }
            $script:export.template.resources.principal.existing = $false
            $script:responses["POST $script:child/exportTemplate?api-version=2025-04-01"] = @{
                StatusCode = 200; Content = $script:export | ConvertTo-Json -Depth 30
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($script:root) -RequireCompleteRemoval
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].DeploymentId | Should -BeExactly $script:child
            @($script:requests | Where-Object { $_ -like 'POST *' }).Count | Should -Be 2
        }
    }
}

Describe 'Bicep registry deployment record confirmation' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:root = '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Resources/deployments/root'
            $script:progress = [System.Collections.Generic.List[string]]::new()
            $script:onProgress = { param($Id, $Status) $script:progress.Add("$Id`:$Status") }
            Mock Start-Sleep {}
            Mock Invoke-AzRestMethod {
                param($Method)
                if ($Method -eq 'DELETE') { return @{ StatusCode = 202; Content = '' } }
                @{ StatusCode = 200; Content = @{ id = $script:root; properties = @{ provisioningState = 'Failed' } } | ConvertTo-Json }
            }
        }
    }

    It 'retains accepted deletion progress without claiming absence or repeating DELETE' {
        InModuleScope Avm.Authoring {
            { Remove-AvmBicepDeploymentRecord -DeploymentIds @($script:root) -OnProgress $script:onProgress } |
                Should -Throw '*still exists*'
            $script:progress | Should -Be @("$script:root`:Pending")
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter { $Method -eq 'DELETE' }
            Should -Invoke Invoke-AzRestMethod -Exactly 3 -ParameterFilter { $Method -eq 'GET' }
            Should -Invoke Start-Sleep -Exactly 2 -ParameterFilter { $Seconds -eq 15 }
        }
    }

    It 'confirms an already accepted deletion with GET only: <Kind>' -ForEach @(
        @{ Kind = 'integer status'; HttpStatus = 404 }
        @{ Kind = 'enum status'; HttpStatus = [System.Net.HttpStatusCode]::NotFound }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ HttpStatus = $HttpStatus } {
            param($HttpStatus)
            $script:confirmationStatus = $HttpStatus
            Mock Invoke-AzRestMethod { @{ StatusCode = $script:confirmationStatus; Content = '{"error":{"code":"DeploymentNotFound"}}' } }
            Remove-AvmBicepDeploymentRecord -DeploymentIds @($script:root) -ConfirmOnly -OnProgress $script:onProgress
            $script:progress | Should -Be @("$script:root`:Complete")
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter { $Method -eq 'GET' }
            Should -Invoke Invoke-AzRestMethod -Exactly 0 -ParameterFilter { $Method -eq 'DELETE' }
        }
    }

    It 'rejects malformed native HTTP status without recording progress: <Kind>' -ForEach @(
        @{ Kind = 'Boolean'; HttpStatus = $true }
        @{ Kind = 'string'; HttpStatus = '404' }
        @{ Kind = 'floating point'; HttpStatus = 404.0 }
        @{ Kind = 'singleton array'; HttpStatus = @(404) }
        @{ Kind = 'missing'; HttpStatus = $null }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ HttpStatus = $HttpStatus } {
            param($HttpStatus)
            $script:confirmation = @{ StatusCode = $HttpStatus; Content = '{"error":{"code":"DeploymentNotFound"}}' }
            Mock Invoke-AzRestMethod { $script:confirmation }
            { Remove-AvmBicepDeploymentRecord -DeploymentIds @($script:root) -ConfirmOnly -OnProgress $script:onProgress } |
                Should -Throw '*Invalid deployment record response*'
            { Remove-AvmBicepDeploymentRecord -DeploymentIds @($script:root) -OnProgress $script:onProgress } |
                Should -Throw '*Deployment record removal failed*'
            $script:progress.Count | Should -Be 0
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter { $Method -eq 'GET' }
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter { $Method -eq 'DELETE' }
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'rejects ambiguous confirmation without further waits: <Body>' -ForEach @(
        @{ Body = '{}'; HttpStatus = 200 }
        @{ Body = '{"id":"/other","properties":{"provisioningState":"Failed"}}'; HttpStatus = 200 }
        @{ Body = '{"id":"ROOT","properties":{"provisioningState":"Running"}}'; HttpStatus = 200 }
        @{ Body = '{"error":{"code":["DeploymentNotFound"]}}'; HttpStatus = 404 }
        @{ Body = '{"error":{"code":"DeploymentNotFound","target":"/other"}}'; HttpStatus = 404 }
        @{ Body = '{"error":{"code":"ResourceGroupNotFound"}}'; HttpStatus = 404 }
        @{ Body = '{"error":{"code":"AuthorizationFailed","code":"DeploymentNotFound"}}'; HttpStatus = 404 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Body = $Body; HttpStatus = $HttpStatus } {
            param($Body, $HttpStatus)
            $script:confirmation = @{ StatusCode = $HttpStatus; Content = $Body.Replace('ROOT', $script:root) }
            Mock Invoke-AzRestMethod { $script:confirmation }
            { Remove-AvmBicepDeploymentRecord -DeploymentIds @($script:root) -ConfirmOnly -OnProgress $script:onProgress } |
                Should -Throw
            $script:progress.Count | Should -Be 0
            Should -Invoke Invoke-AzRestMethod -Exactly 1 -ParameterFilter { $Method -eq 'GET' }
            Should -Invoke Start-Sleep -Exactly 0
        }
    }
}
