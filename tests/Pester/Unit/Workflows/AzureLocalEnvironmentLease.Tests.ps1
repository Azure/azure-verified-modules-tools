#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:actionRoot = Join-Path $script:repoRoot '.github' 'actions' 'azure-local-environment-lease'
    . (Join-Path $script:actionRoot 'Invoke-AzureLocalEnvironmentLease.ps1')

    $script:storageId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-state/providers/Microsoft.Storage/storageAccounts/avmstateaccount'
    $script:fixtureId = '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-avm-azure-local-control'
    $fixtureSubscription = '22222222-2222-4222-8222-222222222222'
    $fixtureDigest = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fixtureSubscription))
    ).ToLowerInvariant()
    $script:blobName = "avm-hci-$fixtureDigest"
    $script:ownerHash = 'b' * 64
    $script:otherOwnerHash = 'c' * 64
    $script:generation = 'd' * 32
    $script:newGeneration = 'e' * 32
    $script:now = [datetime]::UtcNow.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffffffK', [Globalization.CultureInfo]::InvariantCulture
    )
    $script:fixtureTenant = '33333333-3333-4333-8333-333333333333'
}

Describe 'Azure Local environment lease action contract' {
    It 'exposes only the cooperative CAS contract and a fixed action entry point' {
        $action = Get-Content -LiteralPath (Join-Path $script:actionRoot 'action.yml') -Raw
        $action | Should -Match 'storageAccountResourceId:'
        $action | Should -Match 'fixtureResourceGroupId:'
        $action | Should -Match 'ownerHash:'
        $action | Should -Match 'expectedGeneration:'
        $action | Should -Match 'allowUninitialized:'
        $action | Should -Match 'cleanupConfirmed:'
        $action | Should -Match 'expectedOwnerHash:'
        $action | Should -Not -Match 'lease-id|leaseId|leaseDuration'
        $action | Should -Match 'Invoke-AzureLocalEnvironmentLease\.ps1.*-Execute'
        $script = Get-Content -LiteralPath (Join-Path $script:actionRoot 'Invoke-AzureLocalEnvironmentLease.ps1') -Raw
        $script | Should -Match "Name = 'ownerHash'"
        $script | Should -Match "Name = 'updatedAtUtc'"
        $script | Should -Match "Name = 'fixtureExists'"
        $script | Should -Match "Name = 'fixtureGeneration'"
    }

    It 'rejects unsupported target identifiers' {
        $cases = @(
            @{
                StorageId = '/subscriptions/not-a-guid/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/validaccount'
                FixtureId = $script:fixtureId; Container = 'avm-locks'; Blob = $script:blobName
            }
            @{
                StorageId = $script:storageId
                FixtureId = '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/../bad'
                Container = 'avm-locks'; Blob = $script:blobName
            }
            @{
                StorageId = $script:storageId; FixtureId = $script:fixtureId
                Container = 'AVM-locks'; Blob = $script:blobName
            }
            @{
                StorageId = $script:storageId; FixtureId = $script:fixtureId
                Container = 'avm-locks'; Blob = 'avm-hci-short'
            }
            @{
                StorageId = $script:storageId; FixtureId = $script:fixtureId
                Container = 'avm-locks'; Blob = ('avm-hci-' + ('a' * 64))
            }
        )
        foreach ($case in $cases) {
            {
                Get-AzureLocalLockTarget -StorageAccountResourceId $case.StorageId `
                    -FixtureResourceGroupId $case.FixtureId -ContainerName $case.Container -BlobName $case.Blob
            } | Should -Throw
        }
    }
}

Describe 'Azure Local environment lease transitions' {
    BeforeEach {
        $script:fixtureExists = $true
        $script:fixtureGeneration = $script:generation
        $script:ownedGroups = 'rg-avm-azure-local-foundation;rg-avm-azure-local-image;rg-avm-azure-local-staging'
        $script:resolvedStorageId = $script:storageId
        $script:storageTags = @{
            lifecycle = 'tenant-persistent'
            'avm-owner' = 'Azure/bicep-registry-modules'
            'avm-environment' = 'azure-local'
            'avm-purpose' = 'image-operation-receipts'
            'avm-receipt-version' = '1'
            'avm-tenant' = $script:fixtureTenant
            'avm-subscription' = '22222222-2222-4222-8222-222222222222'
        }
        $script:snapshot = [pscustomobject]@{
            Exists = $false
            ETag = $null
            Record = $null
        }
        $script:lastRecord = $null
        Mock Invoke-AzureLocalJsonRead {
            param($ProcessInvoker, $Arguments, $Description)
            if ($Arguments[0] -ceq 'account') {
                $subscription = $Arguments[$Arguments.IndexOf('--subscription') + 1]
                return @{
                    id = $subscription; tenantId = $script:fixtureTenant
                    user = @{ type = 'servicePrincipal' }
                }
            }
            if ($Arguments[0] -ceq 'storage' -and $Arguments[1] -ceq 'account' -and $Arguments[2] -ceq 'show') {
                return @{ id = $script:resolvedStorageId; tags = $script:storageTags }
            }
            if ($Arguments[0] -ceq 'group' -and $Arguments[1] -ceq 'exists') {
                return $script:fixtureExists
            }
            if ($Arguments[0] -ceq 'group' -and $Arguments[1] -ceq 'show') {
                return @{ generation = $script:fixtureGeneration; ownedGroups = $script:ownedGroups }
            }
            throw "Unexpected JSON command: $($Arguments -join ' ')"
        }
        Mock Get-AzureLocalLockSnapshot { return $script:snapshot }
        Mock Set-AzureLocalLockSnapshot {
            param($Target, $Record, $Current, $ProcessInvoker)
            $script:lastRecord = [hashtable]$Record
            $script:snapshot = [pscustomobject]@{
                Exists = $true
                ETag = '"0xNEXT"'
                Record = [hashtable]$Record
            }
            return $script:snapshot
        }
        $script:base = @{
            StorageAccountResourceId = $script:storageId
            FixtureResourceGroupId = $script:fixtureId
            ContainerName = 'avm-locks'
            BlobName = $script:blobName
            ProcessInvoker = { throw 'The fixture should intercept process calls.' }
        }
    }

    It 'atomically initializes an absent lock after proving the fixture exists' {
        $result = Invoke-AzureLocalEnvironmentLease @script:base -Operation acquire -Mode consumer `
            -OwnerHash $script:ownerHash -ExpectedGeneration $script:generation

        $result.Acquired | Should -BeTrue
        $result.FixtureExists | Should -BeTrue
        $script:lastRecord.state | Should -BeExactly 'leased'
        $script:lastRecord.ownerHash | Should -BeExactly $script:ownerHash
        $script:lastRecord.generation | Should -BeExactly $script:generation
        Should -Invoke Set-AzureLocalLockSnapshot -Exactly 1
    }

    It 'projects the current authoritative fixture generation during status' {
        $result = Invoke-AzureLocalEnvironmentLease @script:base -Operation status -Mode consumer

        $result.State | Should -BeExactly 'missing'
        $result.FixtureExists | Should -BeTrue
        $result.FixtureGeneration | Should -BeExactly $script:generation
        Should -Invoke Set-AzureLocalLockSnapshot -Exactly 0
    }

    It 'permits lifecycle initial prepare only with proven absent fixture and no generation' {
        $script:fixtureExists = $false
        $result = Invoke-AzureLocalEnvironmentLease @script:base -Operation acquire -Mode lifecycle `
            -OwnerHash $script:ownerHash -AllowUninitialized $true

        $result.Acquired | Should -BeTrue
        $result.FixtureExists | Should -BeFalse
        $script:lastRecord.generation | Should -BeExactly ''
    }

    It 'permits uninitialized control-group storage only when teardown explicitly excludes the control group' {
        $storageId =
            '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-avm-azure-local-control/providers/Microsoft.Storage/storageAccounts/avmstateaccount'
        $script:resolvedStorageId = $storageId
        $script:fixtureGeneration = ''
        $parameters = @{} + $script:base
        $parameters.StorageAccountResourceId = $storageId

        $result = Invoke-AzureLocalEnvironmentLease @parameters -Operation acquire -Mode lifecycle `
            -OwnerHash $script:ownerHash -AllowUninitialized $true
        $result.Acquired | Should -BeTrue
        $result.FixtureExists | Should -BeTrue
        $result.FixtureGeneration | Should -BeExactly ''

        $script:snapshot = [pscustomobject]@{ Exists = $false; ETag = $null; Record = $null }
        $script:ownedGroups = 'rg-avm-azure-local-control;rg-avm-azure-local-foundation'
        {
            Invoke-AzureLocalEnvironmentLease @parameters -Operation acquire -Mode lifecycle `
                -OwnerHash $script:ownerHash -AllowUninitialized $true
        } | Should -Throw '*explicitly excluded from BRM avm-owned-groups*'
    }

    It 'requires exact persistent receipt-account tags' {
        $script:storageTags['avm-purpose'] = 'different-purpose'
        {
            Invoke-AzureLocalEnvironmentLease @script:base -Operation status
        } | Should -Throw '*exact BRM persistent receipt-account tags*'
        Should -Invoke Get-AzureLocalLockSnapshot -Exactly 0
    }

    It 'rejects consumer use of an absent fixture' {
        $script:fixtureExists = $false
        {
            Invoke-AzureLocalEnvironmentLease @script:base -Operation acquire -Mode consumer `
                -OwnerHash $script:ownerHash -ExpectedGeneration $script:generation
        } | Should -Throw '*control resource group is absent*'
        Should -Invoke Set-AzureLocalLockSnapshot -Exactly 0
    }

    It 'rejects allowUninitialized when the fixture exists' {
        {
            Invoke-AzureLocalEnvironmentLease @script:base -Operation acquire -Mode lifecycle `
                -OwnerHash $script:ownerHash -AllowUninitialized $true
        } | Should -Throw '*no authoritative generation*'
        Should -Invoke Set-AzureLocalLockSnapshot -Exactly 0
    }

    It 'rejects an expected generation that differs from the control tag' {
        $script:fixtureGeneration = $script:newGeneration
        {
            Invoke-AzureLocalEnvironmentLease @script:base -Operation acquire -Mode consumer `
                -OwnerHash $script:ownerHash -ExpectedGeneration $script:generation
        } | Should -Throw '*does not match the authoritative*'
        Should -Invoke Get-AzureLocalLockSnapshot -Exactly 0
    }

    It 'rejects a supplied storage resource ID that does not resolve in Azure' {
        $script:resolvedStorageId =
            '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-avm-azure-local-control/providers/Microsoft.Storage/storageAccounts/avmstateaccount'
        {
            Invoke-AzureLocalEnvironmentLease @script:base -Operation status
        } | Should -Throw '*does not match the Azure-resolved account*'
        Should -Invoke Get-AzureLocalLockSnapshot -Exactly 0
    }

    It 'allows same-owner handoff at the same generation without rewriting' {
        $script:snapshot = [pscustomobject]@{
            Exists = $true
            ETag = '"0xCURRENT"'
            Record = [hashtable]@{
                schemaVersion = 1; state = 'leased'; ownerHash = $script:ownerHash
                generation = $script:generation; acquiredAtUtc = $script:now; updatedAtUtc = $script:now
            }
        }
        $result = Invoke-AzureLocalEnvironmentLease @script:base -Operation acquire -Mode lifecycle `
            -OwnerHash $script:ownerHash -ExpectedGeneration $script:generation

        $result.Acquired | Should -BeTrue
        Should -Invoke Set-AzureLocalLockSnapshot -Exactly 0
    }

    It 'requires explicit lifecycle refresh for a same-owner generation transition' {
        $script:snapshot = [pscustomobject]@{
            Exists = $true
            ETag = '"0xCURRENT"'
            Record = [hashtable]@{
                schemaVersion = 1; state = 'leased'; ownerHash = $script:ownerHash
                generation = $script:generation; acquiredAtUtc = $script:now; updatedAtUtc = $script:now
            }
        }
        $script:fixtureGeneration = $script:newGeneration
        {
            Invoke-AzureLocalEnvironmentLease @script:base -Operation acquire -Mode lifecycle `
                -OwnerHash $script:ownerHash -ExpectedGeneration $script:newGeneration
        } | Should -Throw '*explicit lifecycle refresh*'

        $null = Invoke-AzureLocalEnvironmentLease @script:base -Operation acquire -Mode lifecycle `
            -OwnerHash $script:ownerHash -ExpectedGeneration $script:newGeneration -RefreshGeneration $true
        $script:lastRecord.generation | Should -BeExactly $script:newGeneration
    }

    It 'rejects another owner while acquired' {
        $script:snapshot = [pscustomobject]@{
            Exists = $true
            ETag = '"0xCURRENT"'
            Record = [hashtable]@{
                schemaVersion = 1; state = 'leased'; ownerHash = $script:otherOwnerHash
                generation = $script:generation; acquiredAtUtc = $script:now; updatedAtUtc = $script:now
            }
        }
        {
            Invoke-AzureLocalEnvironmentLease @script:base -Operation acquire -Mode consumer `
                -OwnerHash $script:ownerHash -ExpectedGeneration $script:generation
        } | Should -Throw '*different owner*'
        Should -Invoke Set-AzureLocalLockSnapshot -Exactly 0
    }

    It 'releases only with exact owner, generation, and verified cleanup' {
        $script:snapshot = [pscustomobject]@{
            Exists = $true
            ETag = '"0xCURRENT"'
            Record = [hashtable]@{
                schemaVersion = 1; state = 'leased'; ownerHash = $script:ownerHash
                generation = $script:generation; acquiredAtUtc = $script:now; updatedAtUtc = $script:now
            }
        }
        {
            Invoke-AzureLocalEnvironmentLease @script:base -Operation release `
                -OwnerHash $script:ownerHash -ExpectedGeneration $script:generation
        } | Should -Throw '*cleanupConfirmed=true*'

        $result = Invoke-AzureLocalEnvironmentLease @script:base -Operation release `
            -OwnerHash $script:ownerHash -ExpectedGeneration $script:generation -CleanupConfirmed $true
        $result.Acquired | Should -BeFalse
        $script:lastRecord.state | Should -BeExactly 'released'
        $script:lastRecord.releasedAtUtc | Should -Not -BeNullOrEmpty
    }

    It 'permits recovery only with exact stale ownership evidence' {
        $script:snapshot = [pscustomobject]@{
            Exists = $true
            ETag = '"0xCURRENT"'
            Record = [hashtable]@{
                schemaVersion = 1; state = 'leased'; ownerHash = $script:ownerHash
                generation = $script:generation; acquiredAtUtc = $script:now; updatedAtUtc = $script:now
            }
        }
        {
            Invoke-AzureLocalEnvironmentLease @script:base -Operation recover `
                -ExpectedOwnerHash $script:otherOwnerHash -ExpectedGeneration $script:generation `
                -OwnerInactiveConfirmed $true -RecoveryReason 'cancelled operator-verified run'
        } | Should -Throw '*exactly match*'

        $result = Invoke-AzureLocalEnvironmentLease @script:base -Operation recover `
            -ExpectedOwnerHash $script:ownerHash -ExpectedGeneration $script:generation `
            -OwnerInactiveConfirmed $true -RecoveryReason 'cancelled operator-verified run'
        $script:lastRecord.state | Should -BeExactly 'released'
        $script:lastRecord.recoveryReason | Should -BeExactly 'cancelled operator-verified run'
        $result.Acquired | Should -BeFalse
    }
}

Describe 'Azure Local conditional write readback' {
    It 'accepts an ambiguous failed response only after observing the exact desired state' {
        $target = Get-AzureLocalLockTarget -StorageAccountResourceId $script:storageId `
            -FixtureResourceGroupId $script:fixtureId -ContainerName 'avm-locks' -BlobName $script:blobName
        $record = [hashtable]@{
            schemaVersion = 1; state = 'leased'; ownerHash = $script:ownerHash
            generation = $script:generation; acquiredAtUtc = $script:now; updatedAtUtc = $script:now
        }
        Mock Get-AzureLocalLockSnapshot {
            [pscustomobject]@{ Exists = $true; ETag = '"0xREADBACK"'; Record = $record }
        }
        $invoker = {
            param($Arguments, [switch]$ReadOnly)
            $script:uploadArguments = @($Arguments)
            [pscustomobject]@{ ExitCode = 17; StdOut = ''; StdErr = 'ambiguous' }
        }
        $current = [pscustomobject]@{ Exists = $true; ETag = '"0xBEFORE"'; Record = @{} }

        $result = Set-AzureLocalLockSnapshot -Target $target -Record $record `
            -Current $current -ProcessInvoker $invoker
        $result.Record.state | Should -BeExactly 'leased'
        $script:uploadArguments | Should -Contain '--if-match'
        $script:uploadArguments | Should -Contain '"0xBEFORE"'
    }

    It 'uses If-None-Match for initialization and refuses a competing write' {
        $target = Get-AzureLocalLockTarget -StorageAccountResourceId $script:storageId `
            -FixtureResourceGroupId $script:fixtureId -ContainerName 'avm-locks' -BlobName $script:blobName
        $desired = [hashtable]@{
            schemaVersion = 1; state = 'leased'; ownerHash = $script:ownerHash
            generation = $script:generation; acquiredAtUtc = $script:now; updatedAtUtc = $script:now
        }
        $competing = [hashtable]@{} + $desired
        $competing.ownerHash = $script:otherOwnerHash
        Mock Get-AzureLocalLockSnapshot {
            [pscustomobject]@{ Exists = $true; ETag = '"0xWINNER"'; Record = $competing }
        }
        $invoker = {
            param($Arguments, [switch]$ReadOnly)
            $script:uploadArguments = @($Arguments)
            [pscustomobject]@{ ExitCode = 3; StdOut = ''; StdErr = 'ConditionNotMet' }
        }
        $current = [pscustomobject]@{ Exists = $false; ETag = $null; Record = $null }

        {
            Set-AzureLocalLockSnapshot -Target $target -Record $desired `
                -Current $current -ProcessInvoker $invoker
        } | Should -Throw '*Conditional Azure Local lock write failed*'
        $script:uploadArguments | Should -Contain '--if-none-match'
        $script:uploadArguments | Should -Contain '*'
    }
}
