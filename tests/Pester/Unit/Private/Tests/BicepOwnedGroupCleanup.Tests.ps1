#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:subscription = '00000000-0000-0000-0000-000000000001'
    $script:tenant = '00000000-0000-0000-0000-000000000002'
    $script:runId = '0123456789abcdef0123456789abcdef'
    $script:groupName = 'team0123456789-rg'
    $script:groupId = "/subscriptions/$script:subscription/resourceGroups/$script:groupName"
    $script:deploymentName = "avm-e2e-$script:runId"
    $script:rootDeploymentId = "/subscriptions/$script:subscription/providers/Microsoft.Resources/deployments/$script:deploymentName"
    $script:nestedName = 'inner-0123456789'
    $script:nestedId = "$script:groupId/providers/Microsoft.Resources/deployments/$script:nestedName"
    $script:telemetryName = 'telemetry-0123456789'
    $script:telemetryId = "$script:groupId/providers/Microsoft.Resources/deployments/$script:telemetryName"
    $script:resourceName = 'team0123456789nrtmin001'
    $script:resourceId = "$script:groupId/providers/Microsoft.Network/routeTables/$script:resourceName"
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep nested group operation and cleanup provenance' {
    BeforeEach {
        $script:state = [pscustomobject]@{
            RootId           = $script:rootDeploymentId
            NestedId         = $script:nestedId
            TelemetryId      = $script:telemetryId
            GroupId          = $script:groupId
            GroupName        = $script:groupName
            NestedName       = $script:nestedName
            TelemetryName    = $script:telemetryName
            RouteId          = $script:resourceId
            RouteName        = $script:resourceName
            RunId            = $script:runId
            GroupExists      = $true
            RouteExists      = $true
            GroupTag         = $script:runId
            GroupTags        = $null
            RouteTag         = $null
            NestedHistory    = $true
            IncludeTelemetry = $false
            UpdateOperation  = $false
            RunningOperation = $false
            DuplicateOperation = $false
            MissingOperation = $false
            WrongTargetName  = $false
            ForeignOperation = $false
            GroupContents    = @()
            RouteDeletes     = 0
            GroupDeletes     = 0
            Calls            = [System.Collections.Generic.List[object]]::new()
        }
        $script:plan = InModuleScope 'Avm.Authoring' -Parameters @{
            S = $script:subscription; R = $script:runId
            G = $script:groupName; GroupId = $script:groupId
            RouteId = $script:resourceId; NestedId = $script:nestedId
        } {
            param($S, $R, $G, $GroupId, $RouteId, $NestedId)
            [pscustomobject]@{
                OwnedGroupName = $G
                Resources      = @(
                    (Get-AvmBicepScopedResource -ResourceId $GroupId `
                            -Scope sub -SubscriptionId $S -RunId $R -OwnedGroupName $G)
                    (Get-AvmBicepScopedResource -ResourceId $RouteId `
                            -Scope sub -SubscriptionId $S -RunId $R -OwnedGroupName $G)
                )
                Deployments    = @(
                    (Get-AvmBicepScopedResource -ResourceId $NestedId `
                            -Scope sub -SubscriptionId $S -RunId $R -OwnedGroupName $G)
                )
            }
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ State = $script:state } {
            param($State)
            $script:ownedCleanupState = $State
            Mock Assert-AvmBicepScopedAccount {}
            Mock Invoke-AvmProcess {
                param($FilePath, $ArgumentList)
                $state = $script:ownedCleanupState
                $state.Calls.Add([string[]]$ArgumentList)
                $command = [string]$ArgumentList[0]
                if ($command -eq 'deployment') {
                    $scope = if ($ArgumentList[1] -eq 'operation') {
                        [string]$ArgumentList[2]
                    }
                    else { [string]$ArgumentList[1] }
                    $action = if ($ArgumentList[1] -eq 'operation') {
                        [string]$ArgumentList[3]
                    }
                    else { [string]$ArgumentList[2] }
                    $nameIndex = [array]::IndexOf($ArgumentList, '--name')
                    $requestedName = [string]$ArgumentList[$nameIndex + 1]
                    if ($action -eq 'show') {
                        if ($scope -eq 'group' -and -not $state.NestedHistory) {
                            return [pscustomobject]@{
                                ExitCode = 1; StdOut = ''; StdErr = '(DeploymentNotFound) missing'
                            }
                        }
                        $id = if ($requestedName -eq $state.TelemetryName) {
                            $state.TelemetryId
                        }
                        elseif ($scope -eq 'group') { $state.NestedId } else { $state.RootId }
                        $name = $requestedName
                        return [pscustomobject]@{
                            ExitCode = 0
                            StdOut = @{
                                id = $id; name = $name
                                properties = @{ provisioningState = 'Succeeded' }
                            } | ConvertTo-Json -Compress
                            StdErr = ''
                        }
                    }
                    if ($action -eq 'list') {
                        if ($scope -eq 'group') {
                            $operations = @()
                            if ($requestedName -eq $state.TelemetryName) {
                                $operations += @{
                                    id = "$($state.TelemetryId)/operations/output"
                                    operationId = 'output'
                                    properties = @{
                                        provisioningOperation = 'EvaluateDeploymentOutput'
                                        targetResource = $null
                                    }
                                }
                            }
                            elseif (-not $state.MissingOperation) {
                                $routeOperation = if ($state.UpdateOperation) { 'Update' } else { 'Create' }
                                $routeName = if ($state.WrongTargetName) { 'another-route' } else {
                                    $state.RouteName
                                }
                                $operations += @{
                                    id = "$($state.NestedId)/operations/one"
                                    operationId = 'one'
                                    properties = @{
                                        provisioningOperation = $routeOperation
                                        provisioningState = if ($state.RunningOperation) {
                                            'Running'
                                        }
                                        else { 'Succeeded' }
                                        targetResource = @{
                                            id = $state.RouteId
                                            resourceType = 'Microsoft.Network/routeTables'
                                            resourceName = $routeName
                                        }
                                    }
                                }
                                if ($state.DuplicateOperation) {
                                    $operations += @{
                                        id = "$($state.NestedId)/operations/two"
                                        operationId = 'two'
                                        properties = @{
                                            provisioningOperation = 'Create'
                                            provisioningState = 'Succeeded'
                                            targetResource = @{
                                                id = $state.RouteId
                                                resourceType = 'Microsoft.Network/routeTables'
                                                resourceName = $state.RouteName
                                            }
                                        }
                                    }
                                }
                                if ($state.IncludeTelemetry) {
                                    $operations += @{
                                        id = "$($state.NestedId)/operations/telemetry"
                                        operationId = 'telemetry'
                                        properties = @{
                                            provisioningOperation = 'Create'
                                            provisioningState = 'Succeeded'
                                            targetResource = @{
                                                id = $state.TelemetryId
                                                resourceType = 'Microsoft.Resources/deployments'
                                                resourceName = $state.TelemetryName
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        else {
                            $operations = @(
                                @{
                                    id = "$($state.RootId)/operations/one"
                                    operationId = 'one'
                                    properties = @{
                                        provisioningOperation = 'Create'
                                        provisioningState = 'Succeeded'
                                        targetResource = @{
                                            id = $state.GroupId
                                            resourceType = 'Microsoft.Resources/resourceGroups'
                                            resourceName = $state.GroupName
                                        }
                                    }
                                }
                                @{
                                    id = "$($state.RootId)/operations/two"
                                    operationId = 'two'
                                    properties = @{
                                        provisioningOperation = 'Create'
                                        provisioningState = 'Succeeded'
                                        targetResource = @{
                                            id = $state.NestedId
                                            resourceType = 'Microsoft.Resources/deployments'
                                            resourceName = $state.NestedName
                                        }
                                    }
                                }
                            )
                            if ($state.ForeignOperation) {
                                $operations += @{
                                    id = "$($state.RootId)/operations/three"
                                    operationId = 'three'
                                    properties = @{
                                        provisioningOperation = 'Create'
                                        provisioningState = 'Succeeded'
                                        targetResource = @{
                                            id = $state.RouteId.Replace($state.GroupName, 'foreign-rg')
                                            resourceType = 'Microsoft.Network/routeTables'
                                            resourceName = $state.RouteName
                                        }
                                    }
                                }
                            }
                        }
                        return [pscustomobject]@{
                            ExitCode = 0
                            StdOut = ConvertTo-Json -InputObject @($operations) -Depth 10 -Compress
                            StdErr = ''
                        }
                    }
                }
                if ($command -eq 'group') {
                    switch ($ArgumentList[1]) {
                        'exists' {
                            return [pscustomobject]@{
                                ExitCode = 0
                                StdOut = $state.GroupExists.ToString().ToLowerInvariant()
                                StdErr = ''
                            }
                        }
                        'show' {
                            $tags = if ($null -eq $state.GroupTags) {
                                @{ 'avm-e2e-run-id' = $state.GroupTag }
                            }
                            else { $state.GroupTags }
                            return [pscustomobject]@{
                                ExitCode = 0
                                StdOut = @{
                                    id = $state.GroupId
                                    name = $state.GroupName
                                    type = 'Microsoft.Resources/resourceGroups'
                                    tags = $tags
                                } | ConvertTo-Json -Compress
                                StdErr = ''
                            }
                        }
                        'delete' {
                            $state.GroupExists = $false
                            $state.GroupDeletes++
                            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                        }
                    }
                }
                if ($command -eq 'resource') {
                    switch ($ArgumentList[1]) {
                        'show' {
                            if (-not $state.RouteExists) {
                                return [pscustomobject]@{
                                    ExitCode = 1; StdOut = ''; StdErr = '(ResourceNotFound) missing'
                                }
                            }
                            $shown = @{
                                id = $state.RouteId
                                name = $state.RouteName
                                type = 'Microsoft.Network/routeTables'
                            }
                            if ($null -ne $state.RouteTag) {
                                $shown.tags = $state.RouteTag
                            }
                            return [pscustomobject]@{
                                ExitCode = 0; StdOut = $shown | ConvertTo-Json -Compress
                                StdErr = ''
                            }
                        }
                        'delete' {
                            $state.RouteExists = $false
                            $state.RouteDeletes++
                            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                        }
                        'list' {
                            return [pscustomobject]@{
                                ExitCode = 0
                                StdOut = ConvertTo-Json -InputObject @($state.GroupContents) `
                                    -Depth 5 -Compress
                                StdErr = ''
                            }
                        }
                    }
                }
                throw "Unexpected fake CLI call: $($ArgumentList -join ' ')"
            }
        }
    }

    It 'follows the exact subscription and group deployment operations before deleting owned children and an empty group' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            S = $script:subscription; T = $script:tenant; R = $script:runId
            N = $script:deploymentName; G = $script:groupName; Plan = $script:plan
        } {
            param($S, $T, $R, $N, $G, $Plan)
            Remove-AvmBicepScopedDeploymentResource -AzPath 'fake-az' -Scope sub `
                -SubscriptionId $S -TenantId $T -DeploymentName $N `
                -RunId $R -OwnedGroupName $G -Plan $Plan -WorkingDirectory '.' -Confirm:$false
        }
        $result.Cleaned | Should -BeTrue
        $result.Pending.Count | Should -Be 0
        $script:state.RouteDeletes | Should -Be 1
        $script:state.GroupDeletes | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_[0] -eq 'deployment' -and $_[1] -eq 'operation' -and
                $_[2] -eq 'group' -and $_ -contains $script:groupName
            }).Count | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_[0] -eq 'resource' -and $_[1] -eq 'list' -and
                $_ -contains $script:groupName
            }).Count | Should -Be 1
    }

    It 'inspects the optional telemetry-only nested deployment without treating outputs as owned resources' {
        $script:state.IncludeTelemetry = $true
        $telemetry = InModuleScope 'Avm.Authoring' -Parameters @{
            S = $script:subscription; R = $script:runId
            G = $script:groupName; Id = $script:telemetryId
        } {
            param($S, $R, $G, $Id)
            Get-AvmBicepScopedResource -ResourceId $Id -Scope group `
                -SubscriptionId $S -RunId $R -OwnedGroupName $G
        }
        $script:plan.Deployments += $telemetry
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            S = $script:subscription; T = $script:tenant; R = $script:runId
            N = $script:deploymentName; G = $script:groupName; Plan = $script:plan
        } {
            param($S, $T, $R, $N, $G, $Plan)
            Remove-AvmBicepScopedDeploymentResource -AzPath 'fake-az' -Scope sub `
                -SubscriptionId $S -TenantId $T -DeploymentName $N `
                -RunId $R -OwnedGroupName $G -Plan $Plan -WorkingDirectory '.' -Confirm:$false
        }
        $result.Cleaned | Should -BeTrue
        $script:state.RouteDeletes | Should -Be 1
        $script:state.GroupDeletes | Should -Be 1
        @($script:state.Calls | Where-Object {
                $_[0] -eq 'deployment' -and $_[1] -eq 'operation' -and
                $_[2] -eq 'group'
            }).Count | Should -Be 2
    }

    It 'leaves <Case> pending instead of deleting unverified resources or group' -ForEach @(
        @{ Case = 'a foreign ownership tag'; Change = 'tag'; DeleteOwned = $false }
        @{ Case = 'duplicate case-variant group tags'; Change = 'group-tags'; DeleteOwned = $false }
        @{ Case = 'a case-variant foreign child tag'; Change = 'child-tag'; DeleteOwned = $false }
        @{ Case = 'missing nested deployment history'; Change = 'history'; DeleteOwned = $false }
        @{ Case = 'a missing nested operation'; Change = 'missing-operation'; DeleteOwned = $false }
        @{ Case = 'an Update after preflight'; Change = 'update'; DeleteOwned = $false }
        @{ Case = 'a still-running operation'; Change = 'running'; DeleteOwned = $false }
        @{ Case = 'a duplicate Create operation'; Change = 'duplicate'; DeleteOwned = $false }
        @{ Case = 'a mismatched operation name'; Change = 'name'; DeleteOwned = $false }
        @{ Case = 'an operation in a foreign group'; Change = 'foreign-operation'; DeleteOwned = $false }
        @{ Case = 'a foreign resource in the tagged group'; Change = 'foreign-content'; DeleteOwned = $true }
    ) {
        switch ($Change) {
            tag { $script:state.GroupTag = 'another-run' }
            'group-tags' {
                $tags = [System.Collections.Specialized.OrderedDictionary]::new(
                    [System.StringComparer]::Ordinal)
                $tags.Add('avm-e2e-run-id', $script:runId)
                $tags.Add('AVM-E2E-RUN-ID', 'foreign')
                $script:state.GroupTags = $tags
            }
            'child-tag' { $script:state.RouteTag = @{ 'AVM-E2E-RUN-ID' = 'foreign' } }
            history { $script:state.NestedHistory = $false }
            'missing-operation' { $script:state.MissingOperation = $true }
            update { $script:state.UpdateOperation = $true }
            running { $script:state.RunningOperation = $true }
            duplicate { $script:state.DuplicateOperation = $true }
            name { $script:state.WrongTargetName = $true }
            'foreign-operation' { $script:state.ForeignOperation = $true }
            'foreign-content' {
                $script:state.GroupContents = @(@{
                        id = "$script:groupId/providers/Microsoft.Storage/storageAccounts/foreign"
                    })
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            S = $script:subscription; T = $script:tenant; R = $script:runId
            N = $script:deploymentName; G = $script:groupName; Plan = $script:plan
        } {
            param($S, $T, $R, $N, $G, $Plan)
            Remove-AvmBicepScopedDeploymentResource -AzPath 'fake-az' -Scope sub `
                -SubscriptionId $S -TenantId $T -DeploymentName $N `
                -RunId $R -OwnedGroupName $G -Plan $Plan -WorkingDirectory '.' -Confirm:$false
        }
        $result.Cleaned | Should -BeFalse
        $result.Pending | Should -Contain $script:groupId
        $script:state.RouteDeletes | Should -Be ([int]$DeleteOwned)
        $script:state.GroupDeletes | Should -Be 0
        if ($Change -eq 'foreign-content') {
            $result.Pending | Should -Contain $script:state.GroupContents[0].id
        }
        if ($Change -eq 'foreign-operation') {
            $result.Pending | Should -Contain (
                $script:resourceId.Replace($script:groupName, 'foreign-rg'))
        }
    }

    It 'refuses a forged group plan before querying any Azure endpoint' {
        $script:plan.OwnedGroupName = 'foreign-rg'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            S = $script:subscription; T = $script:tenant; R = $script:runId
            N = $script:deploymentName; G = $script:groupName; Plan = $script:plan
        } {
            param($S, $T, $R, $N, $G, $Plan)
            Remove-AvmBicepScopedDeploymentResource -AzPath 'fake-az' -Scope sub `
                -SubscriptionId $S -TenantId $T -DeploymentName $N `
                -RunId $R -OwnedGroupName $G -Plan $Plan -WorkingDirectory '.' -Confirm:$false
        }
        $result.Cleaned | Should -BeFalse
        $result.Pending | Should -Contain $script:groupId
        $script:state.Calls.Count | Should -Be 0
    }
}
