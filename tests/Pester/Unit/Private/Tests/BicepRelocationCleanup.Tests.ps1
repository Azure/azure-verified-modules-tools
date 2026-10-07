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
                $script:pages[$script:root + '/operations?api-version=2021-04-01'] = @{ value = $Operations }
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
                Should -Throw '*Deployment state could not be confirmed*'
            $script:invalidResponsePath = $script:root + '/operations?api-version=2021-04-01'
            { Get-AvmBicepDeploymentRetryKind -DeploymentId $script:root } |
                Should -Throw '*Deployment operations could not be read*'
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
                $script:pages[$Id + '/operations?api-version=2021-04-01'] = @{ Status = 200; Body = @{ value = $Operations } }
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
            $script:pages[$script:nested + '/operations?api-version=2021-04-01'] = $script:pages[$script:nested + '?api-version=2021-04-01']
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