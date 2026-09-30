#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:subscription = '00000000-0000-0000-0000-000000000001'
    $script:tenant = '00000000-0000-0000-0000-000000000002'
    $script:runId = '0123456789abcdef0123456789abcdef'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep scoped e2e account verification' {
    It 'requires the selected subscription, tenant and existing management group to match' {
        InModuleScope 'Avm.Authoring' -Parameters @{
            S = $script:subscription; T = $script:tenant
        } {
            param($S, $T)
            $script:scopedAccount = [pscustomobject]@{
                SubscriptionId = $S
                TenantId       = $T
                GroupName      = 'test-group'
            }
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $state = $script:scopedAccount
                if ($ArgumentList[0] -eq 'account' -and $ArgumentList[1] -eq 'show') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = (@{
                                id = $state.SubscriptionId
                                tenantId = $state.TenantId
                                state = 'Enabled'
                            } | ConvertTo-Json -Compress)
                        StdErr = ''
                    }
                }
                if ($ArgumentList[0] -eq 'account' -and
                    $ArgumentList[1] -eq 'management-group') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = (@{
                                id = "/providers/Microsoft.Management/managementGroups/$($state.GroupName)"
                                name = $state.GroupName
                            } | ConvertTo-Json -Compress)
                        StdErr = ''
                    }
                }
                throw "Unexpected account probe: $($ArgumentList -join ' ')"
            }
            Assert-AvmBicepScopedAccount -AzPath 'fake-az' -SubscriptionId $S `
                -TenantId $T -ManagementGroupId 'test-group' -WorkingDirectory '.'
            Should -Invoke Invoke-AvmProcess -Exactly 2

            $script:scopedAccount.TenantId = '00000000-0000-0000-0000-000000000003'
            { Assert-AvmBicepScopedAccount -AzPath 'fake-az' -SubscriptionId $S `
                    -TenantId $T -ManagementGroupId 'test-group' -WorkingDirectory '.' } |
                Should -Throw -ExpectedMessage '*does not confirm*'
            Should -Invoke Invoke-AvmProcess -Exactly 3
        }
    }
}

Describe 'Bicep scoped e2e cleanup provenance' {
    It 'only deletes a proven Create; reports pending resources for <Case>' -ForEach @(
        @{ Case = 'matching creation'; Operation = 'Create'; Unexpected = $false; Cleaned = $true }
        @{ Case = 'an intervening update'; Operation = 'Update'; Unexpected = $false; Cleaned = $false }
        @{ Case = 'an unplanned assignment'; Operation = 'Create'; Unexpected = $true; Cleaned = $false }
    ) {
        $observed = InModuleScope 'Avm.Authoring' -Parameters @{
            S = $script:subscription; T = $script:tenant; R = $script:runId
            Op = $Operation; IsUnexpected = $Unexpected
        } {
            param($S, $T, $R, $Op, $IsUnexpected)
            $name = "avm$($R.Substring(0, 10))-policy"
            $resourceId = "/subscriptions/$S/providers/Microsoft.Authorization/policyDefinitions/$name"
            $deploymentName = "avm-e2e-$R"
            $deploymentId = Get-AvmBicepScopedDeploymentId -Scope sub `
                -SubscriptionId $S -DeploymentName $deploymentName
            $resource = Get-AvmBicepScopedResource -ResourceId $resourceId `
                -Scope sub -SubscriptionId $S -RunId $R
            $plan = [pscustomobject]@{ Resources = @($resource); Deployments = @() }
            $script:scopedCleanup = [pscustomobject]@{
                DeploymentName = $deploymentName
                DeploymentId   = $deploymentId
                ResourceId     = $resourceId
                ResourceName   = $name
                ResourceType   = 'Microsoft.Authorization/policyDefinitions'
                TargetId       = if ($IsUnexpected) {
                    "/subscriptions/$S/providers/Microsoft.Authorization/roleAssignments/foreign"
                }
                else { $resourceId }
                TargetType     = if ($IsUnexpected) {
                    'Microsoft.Authorization/roleAssignments'
                }
                else { 'Microsoft.Authorization/policyDefinitions' }
                Operation      = $Op
                Exists         = $true
                DeleteCount    = 0
            }
            Mock Assert-AvmBicepScopedAccount {}
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $state = $script:scopedCleanup
                if ($ArgumentList[0] -eq 'deployment' -and
                    $ArgumentList[1] -eq 'sub' -and $ArgumentList[2] -eq 'show') {
                    $deployment = @{
                        id = $state.DeploymentId
                        name = $state.DeploymentName
                        properties = @{ provisioningState = 'Succeeded' }
                    }
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = $deployment | ConvertTo-Json -Depth 5 -Compress
                        StdErr = ''
                    }
                }
                if ($ArgumentList[0] -eq 'deployment' -and
                    $ArgumentList[1] -eq 'operation') {
                    $operation = @{
                        id = "$($state.DeploymentId)/operations/one"
                        operationId = 'one'
                        properties = @{
                            provisioningOperation = $state.Operation
                            targetResource = @{
                                id = $state.TargetId
                                resourceType = $state.TargetType
                            }
                        }
                    }
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = ConvertTo-Json -InputObject @($operation) -Depth 8 -Compress
                        StdErr = ''
                    }
                }
                if ($ArgumentList[0] -eq 'resource' -and
                    $ArgumentList[1] -eq 'show') {
                    if (-not $state.Exists) {
                        return [pscustomobject]@{
                            ExitCode = 1; StdOut = ''; StdErr = '(ResourceNotFound) missing'
                        }
                    }
                    $resource = @{
                        id = $state.ResourceId
                        name = $state.ResourceName
                        type = $state.ResourceType
                    }
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = $resource | ConvertTo-Json -Depth 5 -Compress
                        StdErr = ''
                    }
                }
                if ($ArgumentList[0] -eq 'resource' -and
                    $ArgumentList[1] -eq 'delete') {
                    $state.Exists = $false
                    $state.DeleteCount++
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                throw "Unexpected cleanup probe: $($ArgumentList -join ' ')"
            }
            $cleanup = Remove-AvmBicepScopedDeploymentResource -AzPath 'fake-az' `
                -Scope sub -SubscriptionId $S -TenantId $T `
                -DeploymentName $deploymentName -RunId $R -Plan $plan `
                -WorkingDirectory '.' -Confirm:$false
            [pscustomobject]@{
                Result = $cleanup
                DeleteCount = $script:scopedCleanup.DeleteCount
                ResourceId = $resourceId
                ActualId = $script:scopedCleanup.TargetId
            }
        }
        $observed.Result.Cleaned | Should -Be $Cleaned
        $observed.DeleteCount | Should -Be ([int]$Cleaned)
        if ($Cleaned) {
            $observed.Result.Pending.Count | Should -Be 0
        }
        else {
            $observed.Result.Pending | Should -Contain $observed.ResourceId
            if ($Unexpected) {
                $observed.Result.Pending | Should -Contain $observed.ActualId
            }
        }
    }
}
