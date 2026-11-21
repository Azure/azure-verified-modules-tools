#Requires -Version 7.4

[CmdletBinding()]
param([switch] $Execute)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function ConvertTo-AzureLocalBoolean {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value
    )

    if ($Value -ceq 'true') { return $true }
    if ($Value -ceq 'false' -or [string]::IsNullOrEmpty($Value)) { return $false }
    throw [ArgumentException]::new("$Name must be exactly 'true' or 'false'.")
}

function Get-AzureLocalLockTarget {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountResourceId,
        [Parameter(Mandatory)] [string] $FixtureResourceGroupId,
        [Parameter(Mandatory)] [string] $ContainerName,
        [Parameter(Mandatory)] [string] $BlobName
    )

    $match = [regex]::Match(
        $StorageAccountResourceId,
        '\A/subscriptions/(?<subscription>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/resourceGroups/(?<group>[^/]+)/providers/Microsoft\.Storage/storageAccounts/(?<account>[a-z0-9]{3,24})\z',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) {
        throw [ArgumentException]::new('storageAccountResourceId must be one exact storage-account ARM resource ID.')
    }
    $fixtureMatch = [regex]::Match(
        $FixtureResourceGroupId,
        '\A/subscriptions/(?<subscription>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/resourceGroups/(?<group>[^/]+)\z',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $fixtureMatch.Success) {
        throw [ArgumentException]::new('fixtureResourceGroupId must be one exact control resource-group ARM resource ID.')
    }
    $fixtureGroupName = $fixtureMatch.Groups['group'].Value
    if ($fixtureGroupName -cnotmatch '\A[A-Za-z0-9_().-]{1,90}\z' -or $fixtureGroupName.EndsWith('.')) {
        throw [ArgumentException]::new('fixtureResourceGroupId must contain a valid control resource-group name.')
    }
    if ($ContainerName -cnotmatch '\A[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])\z' -or $ContainerName.Contains('--')) {
        throw [ArgumentException]::new('containerName must be a valid private Blob container name.')
    }
    if ($BlobName -cnotmatch '\Aavm-hci-[0-9a-f]{64}\z') {
        throw [ArgumentException]::new('blobName must use the canonical avm-hci-<64 lowercase SHA-256 hex> form.')
    }
    $fixtureSubscription = ([guid]$fixtureMatch.Groups['subscription'].Value).ToString('D')
    $fixtureSubscriptionDigest = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fixtureSubscription))
    ).ToLowerInvariant()
    if ($BlobName -cne "avm-hci-$fixtureSubscriptionDigest") {
        throw [ArgumentException]::new(
            'blobName must be avm-hci- followed by the lowercase UTF-8 SHA-256 of the canonical fixture subscription GUID.'
        )
    }
    return [pscustomobject]@{
        SubscriptionId = ([guid]$match.Groups['subscription'].Value).ToString('D')
        StorageAccountName = $match.Groups['account'].Value.ToLowerInvariant()
        StorageAccountResourceGroupName = $match.Groups['group'].Value
        FixtureSubscriptionId = ([guid]$fixtureMatch.Groups['subscription'].Value).ToString('D')
        FixtureResourceGroupName = $fixtureGroupName
        ContainerName = $ContainerName
        BlobName = $BlobName
    }
}

function ConvertFrom-AzureLocalLockJson {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $Json)

    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($Json)
        $pending = [Collections.Generic.Stack[Text.Json.JsonElement]]::new()
        $pending.Push($document.RootElement)
        while ($pending.Count -gt 0) {
            $element = $pending.Pop()
            if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $seen.Add($property.Name)) {
                        throw [ArgumentException]::new('Lock JSON contains duplicate properties.')
                    }
                    $pending.Push($property.Value)
                }
            }
            elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($item in $element.EnumerateArray()) { $pending.Push($item) }
            }
        }
        return ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate -Depth 10
    }
    catch {
        throw [InvalidDataException]::new('The Azure Local lock blob does not contain valid unique-key JSON.', $_.Exception)
    }
    finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}

function Assert-AzureLocalLockRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Record)

    $allowed = @(
        'schemaVersion', 'state', 'ownerHash', 'generation', 'acquiredAtUtc',
        'updatedAtUtc', 'releasedAtUtc', 'recoveryReason'
    )
    if (@($Record.Keys | Where-Object { $_ -cnotin $allowed }).Count -gt 0) {
        throw [InvalidDataException]::new('The Azure Local lock record contains unsupported properties.')
    }
    if ($Record['schemaVersion'] -ne 1 -or $Record['state'] -cnotin @('leased', 'released') -or
        $Record['ownerHash'] -isnot [string] -or $Record['ownerHash'] -cnotmatch '\A[0-9a-f]{64}\z' -or
        $Record['generation'] -isnot [string] -or
        ($Record['generation'] -cnotmatch '\A(?:|[0-9a-f]{32})\z') -or
        $Record['acquiredAtUtc'] -isnot [string] -or
        $Record['updatedAtUtc'] -isnot [string]) {
        throw [InvalidDataException]::new('The Azure Local lock record has invalid required fields.')
    }
    foreach ($field in @('acquiredAtUtc', 'updatedAtUtc', 'releasedAtUtc')) {
        if ($Record.ContainsKey($field) -and -not [string]::IsNullOrEmpty($Record[$field])) {
            $parsed = [datetime]::MinValue
            if ($Record[$field] -isnot [string] -or
                -not [datetime]::TryParseExact(
                    $Record[$field], 'yyyy-MM-ddTHH:mm:ss.fffffffK', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed
                )) {
                throw [InvalidDataException]::new("The Azure Local lock record has an invalid $field timestamp.")
            }
        }
    }
    if ($Record['state'] -ceq 'released' -and
        ($Record['releasedAtUtc'] -isnot [string] -or [string]::IsNullOrEmpty($Record['releasedAtUtc']))) {
        throw [InvalidDataException]::new('A released Azure Local lock record must include releasedAtUtc.')
    }
    if ($Record.ContainsKey('recoveryReason')) {
        if ($Record['recoveryReason'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($Record['recoveryReason']) -or
            $Record['recoveryReason'].Length -gt 1024 -or
            $Record['recoveryReason'] -match '[\x00-\x1f\x7f]') {
            throw [InvalidDataException]::new('The Azure Local lock recoveryReason is invalid.')
        }
    }
}

function Test-AzureLocalLockRecordEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [hashtable] $Expected,
        [Parameter(Mandatory)] [hashtable] $Actual
    )

    $expectedKeys = @($Expected.Keys | Sort-Object)
    $actualKeys = @($Actual.Keys | Sort-Object)
    if ($expectedKeys.Count -ne $actualKeys.Count) { return $false }
    foreach ($key in $expectedKeys) {
        if ($actualKeys -cnotcontains $key) { return $false }
        if ([string]$Actual[$key] -cne [string]$Expected[$key]) { return $false }
    }
    return $true
}

function Invoke-AzureLocalProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $ReadOnly,
        [string] $Label = 'Azure Local lock operation'
    )

    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
    $module = Import-Module (Join-Path $root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru
    $azPath = (Get-Command -Name az -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $environment = @{}
    foreach ($name in @([Environment]::GetEnvironmentVariables().Keys |
        Where-Object { $_ -like 'AZURE_STORAGE_*' })) {
        $environment[$name] = $null
    }
    return & $module {
        param($Executable, $CommandArguments, $CommandEnvironment, $CommandLabel, $IsReadOnly)
        Invoke-AvmProcess -FilePath $Executable -ArgumentList $CommandArguments `
            -EnvVars $CommandEnvironment -TimeoutSec 60 -IgnoreExitCode -Label $CommandLabel `
            -RetryNetworkFailure:$IsReadOnly
    } $azPath $Arguments $environment $Label $ReadOnly.IsPresent
}

function Invoke-AzureLocalJsonRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $ProcessInvoker,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $Description
    )

    $result = & $ProcessInvoker -Arguments $Arguments -ReadOnly
    if ($result.ExitCode -ne 0) {
        throw [InvalidOperationException]::new("$Description failed (exit $($result.ExitCode)).")
    }
    try {
        return ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -NoEnumerate -Depth 10 -ErrorAction Stop
    }
    catch {
        throw [InvalidDataException]::new("$Description returned invalid JSON.", $_.Exception)
    }
}

function Get-AzureLocalLockSnapshot {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Target,
        [Parameter(Mandatory)] [scriptblock] $ProcessInvoker
    )

    $base = @(
        '--account-name', $Target.StorageAccountName,
        '--container-name', $Target.ContainerName,
        '--name', $Target.BlobName,
        '--auth-mode', 'login', '--subscription', $Target.SubscriptionId,
        '--only-show-errors', '--output', 'json'
    )
    $exists = Invoke-AzureLocalJsonRead -ProcessInvoker $ProcessInvoker -Arguments @(
        'storage', 'blob', 'exists'
    ) + $base -Description 'Azure Local lock existence check'
    if ($exists['exists'] -isnot [bool]) {
        throw [InvalidDataException]::new('Azure Local lock existence check did not return a Boolean.')
    }
    if (-not $exists['exists']) {
        return [pscustomobject]@{ Exists = $false; ETag = $null; Record = $null }
    }

    $show = Invoke-AzureLocalJsonRead -ProcessInvoker $ProcessInvoker -Arguments @(
        'storage', 'blob', 'show'
    ) + $base + @(
        '--query', '{etag:properties.etag,contentLength:properties.contentLength}'
    ) -Description 'Azure Local lock metadata inspection'
    if ($show['etag'] -isnot [string] -or [string]::IsNullOrWhiteSpace($show['etag']) -or
        $show['contentLength'] -isnot [long] -and $show['contentLength'] -isnot [int] -or
        [long]$show['contentLength'] -gt 65536) {
        throw [InvalidDataException]::new('Azure Local lock metadata is incomplete or exceeds 64 KiB.')
    }

    $downloadPath = Join-Path ([IO.Path]::GetTempPath()) ("avm-azure-local-lock-$([guid]::NewGuid().ToString('N')).json")
    try {
        $result = & $ProcessInvoker -Arguments @(
            'storage', 'blob', 'download', '--account-name', $Target.StorageAccountName,
            '--container-name', $Target.ContainerName, '--name', $Target.BlobName,
            '--file', $downloadPath, '--overwrite', 'true', '--if-match', $show['etag'],
            '--auth-mode', 'login', '--subscription', $Target.SubscriptionId,
            '--only-show-errors', '--output', 'none'
        ) -ReadOnly
        if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $downloadPath -PathType Leaf)) {
            throw [InvalidOperationException]::new("Azure Local lock read failed (exit $($result.ExitCode)).")
        }
        $record = ConvertFrom-AzureLocalLockJson -Json ([IO.File]::ReadAllText(
                $downloadPath, [Text.UTF8Encoding]::new($false, $true)
            ))
    }
    finally {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    }
    if ($record -isnot [hashtable]) {
        throw [InvalidDataException]::new('The Azure Local lock blob must contain one JSON object.')
    }
    Assert-AzureLocalLockRecord -Record $record

    $verified = Invoke-AzureLocalJsonRead -ProcessInvoker $ProcessInvoker -Arguments @(
        'storage', 'blob', 'show'
    ) + $base + @('--query', '{etag:properties.etag}') -Description 'Azure Local lock readback verification'
    if ($verified['etag'] -isnot [string] -or $verified['etag'] -cne $show['etag']) {
        throw [InvalidOperationException]::new('The Azure Local lock changed during inspection; no mutation was attempted.')
    }
    return [pscustomobject]@{ Exists = $true; ETag = $show['etag']; Record = $record }
}

function Set-AzureLocalLockSnapshot {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Target,
        [Parameter(Mandatory)] [hashtable] $Record,
        [Parameter(Mandatory)] [AllowNull()] [pscustomobject] $Current,
        [Parameter(Mandatory)] [scriptblock] $ProcessInvoker
    )

    Assert-AzureLocalLockRecord -Record $Record
    $uploadPath = Join-Path ([IO.Path]::GetTempPath()) ("avm-azure-local-lock-$([guid]::NewGuid().ToString('N')).json")
    try {
        [IO.File]::WriteAllText(
            $uploadPath,
            (ConvertTo-Json -InputObject $Record -Depth 10 -Compress),
            [Text.UTF8Encoding]::new($false)
        )
        $arguments = @(
            'storage', 'blob', 'upload', '--account-name', $Target.StorageAccountName,
            '--container-name', $Target.ContainerName, '--name', $Target.BlobName,
            '--file', $uploadPath, '--type', 'block', '--overwrite', 'true',
            '--auth-mode', 'login', '--subscription', $Target.SubscriptionId,
            '--only-show-errors', '--output', 'none'
        )
        if ($Current.Exists) { $arguments += @('--if-match', $Current.ETag) }
        else { $arguments += @('--if-none-match', '*') }
        $result = & $ProcessInvoker -Arguments $arguments
        if ($result.ExitCode -ne 0) {
            $observed = Get-AzureLocalLockSnapshot -Target $Target -ProcessInvoker $ProcessInvoker
            if ($observed.Exists -and
                (Test-AzureLocalLockRecordEqual -Expected $Record -Actual $observed.Record)) {
                return $observed
            }
            throw [InvalidOperationException]::new(
                "Conditional Azure Local lock write failed (exit $($result.ExitCode)); a new lock state was not confirmed."
            )
        }
        $observed = Get-AzureLocalLockSnapshot -Target $Target -ProcessInvoker $ProcessInvoker
        if (-not $observed.Exists -or
            -not (Test-AzureLocalLockRecordEqual -Expected $Record -Actual $observed.Record)) {
            throw [InvalidOperationException]::new('Azure Local lock write readback did not match the requested record.')
        }
        return $observed
    }
    finally {
        Remove-Item -LiteralPath $uploadPath -Force -ErrorAction SilentlyContinue
    }
}

function New-AzureLocalLockRecord {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $State,
        [Parameter(Mandatory)] [string] $OwnerHash,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Generation,
        [datetime] $AcquiredAt = [datetime]::UtcNow,
        [string] $RecoveryReason
    )

    $now = [datetime]::UtcNow
    $record = [ordered]@{
        schemaVersion = 1
        state = $State
        ownerHash = $OwnerHash
        generation = $Generation
        acquiredAtUtc = $AcquiredAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffK', [Globalization.CultureInfo]::InvariantCulture)
        updatedAtUtc = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffffffK', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($State -ceq 'released') {
        $record['releasedAtUtc'] = $record['updatedAtUtc']
    }
    if (-not [string]::IsNullOrEmpty($RecoveryReason)) {
        $record['recoveryReason'] = $RecoveryReason
    }
    return [hashtable]$record
}

function Invoke-AzureLocalEnvironmentLease {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('status', 'acquire', 'release', 'recover')]
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [string] $StorageAccountResourceId,
        [Parameter(Mandatory)] [string] $FixtureResourceGroupId,
        [Parameter(Mandatory)] [string] $ContainerName,
        [Parameter(Mandatory)] [string] $BlobName,
        [string] $OwnerHash = '',
        [AllowEmptyString()] [string] $ExpectedGeneration = '',
        [ValidateSet('consumer', 'lifecycle')]
        [string] $Mode = 'consumer',
        [bool] $RefreshGeneration = $false,
        [bool] $AllowUninitialized = $false,
        [bool] $CleanupConfirmed = $false,
        [string] $ExpectedOwnerHash = '',
        [bool] $OwnerInactiveConfirmed = $false,
        [string] $RecoveryReason = '',
        [scriptblock] $ProcessInvoker
    )

    if ($null -eq $ProcessInvoker) { $ProcessInvoker = ${function:Invoke-AzureLocalProcess} }
    $target = Get-AzureLocalLockTarget -StorageAccountResourceId $StorageAccountResourceId `
        -FixtureResourceGroupId $FixtureResourceGroupId -ContainerName $ContainerName -BlobName $BlobName
    if (-not [string]::IsNullOrEmpty($ExpectedGeneration) -and
        $ExpectedGeneration -cnotmatch '\A[0-9a-f]{32}\z') {
        throw [ArgumentException]::new('expectedGeneration must be an exact lowercase 32-hex avm-generation value when supplied.')
    }
    if (-not [string]::IsNullOrEmpty($OwnerHash) -and $OwnerHash -cnotmatch '\A[0-9a-f]{64}\z') {
        throw [ArgumentException]::new('ownerHash must be an exact lowercase SHA-256 hex value when supplied.')
    }
    if ($AllowUninitialized -and $Mode -cne 'lifecycle') {
        throw [ArgumentException]::new('Only lifecycle operations may allow an uninitialized fixture.')
    }
    $subscriptions = @($target.SubscriptionId, $target.FixtureSubscriptionId) | Select-Object -Unique
    $fixtureTenantId = ''
    foreach ($subscription in $subscriptions) {
        $account = Invoke-AzureLocalJsonRead -ProcessInvoker $ProcessInvoker -Arguments @(
            'account', 'show', '--subscription', $subscription, '--only-show-errors',
            '--output', 'json', '--query', '{id:id,tenantId:tenantId,user:user}'
        ) -Description 'Azure Local lock identity verification'
        if ($account['id'] -isnot [string] -or $account['id'] -ine $subscription -or
            $account['user'] -isnot [Collections.IDictionary] -or
            $account['user']['type'] -ine 'servicePrincipal') {
            throw [InvalidOperationException]::new('Azure CLI must use a service-principal context in every selected subscription.')
        }
        if ($subscription -ieq $target.FixtureSubscriptionId) {
            $fixtureTenantId = [string]$account['tenantId']
        }
    }
    $storageAccount = Invoke-AzureLocalJsonRead -ProcessInvoker $ProcessInvoker -Arguments @(
        'storage', 'account', 'show', '--name', $target.StorageAccountName,
        '--resource-group', $target.StorageAccountResourceGroupName,
        '--subscription', $target.SubscriptionId, '--only-show-errors',
        '--output', 'json', '--query', '{id:id,tags:tags}'
    ) -Description 'Azure Local lock storage account verification'
    if ($storageAccount['id'] -isnot [string] -or
        $storageAccount['id'] -ine $StorageAccountResourceId) {
        throw [InvalidOperationException]::new(
            'The persistent lock storage account resource ID does not match the Azure-resolved account.'
        )
    }
    $storageTags = $storageAccount['tags']
    $requiredStorageTags = [ordered]@{
        lifecycle = 'tenant-persistent'
        'avm-owner' = 'Azure/bicep-registry-modules'
        'avm-environment' = 'azure-local'
        'avm-purpose' = 'image-operation-receipts'
        'avm-receipt-version' = '1'
        'avm-tenant' = $fixtureTenantId.ToLowerInvariant()
        'avm-subscription' = $target.FixtureSubscriptionId
    }
    if ($storageTags -isnot [Collections.IDictionary] -or
        @($requiredStorageTags.Keys | Where-Object {
                [string]$storageTags[$_] -cne [string]$requiredStorageTags[$_]
            }).Count -gt 0) {
        throw [InvalidOperationException]::new(
            'The lock storage account lacks the exact BRM persistent receipt-account tags.'
        )
    }
    $fixture = Invoke-AzureLocalJsonRead -ProcessInvoker $ProcessInvoker -Arguments @(
        'group', 'exists', '--name', $target.FixtureResourceGroupName,
        '--subscription', $target.FixtureSubscriptionId, '--only-show-errors', '--output', 'json'
    ) -Description 'Azure Local control resource-group existence check'
    if ($fixture -isnot [bool]) {
        throw [InvalidDataException]::new('Azure Local control resource-group existence check did not return a Boolean.')
    }
    $fixtureGeneration = ''
    $ownedGroups = ''
    if ($fixture) {
        $generation = Invoke-AzureLocalJsonRead -ProcessInvoker $ProcessInvoker -Arguments @(
            'group', 'show', '--name', $target.FixtureResourceGroupName,
            '--subscription', $target.FixtureSubscriptionId, '--only-show-errors',
            '--output', 'json',
            '--query', '{generation:tags."avm-generation",ownedGroups:tags."avm-owned-groups"}'
        ) -Description 'Azure Local control resource-group generation inspection'
        $fixtureGeneration = [string]$generation['generation']
        $ownedGroups = [string]$generation['ownedGroups']
        if (($Mode -ceq 'consumer' -or -not [string]::IsNullOrEmpty($ExpectedGeneration)) -and
            $fixtureGeneration -cnotmatch '\A[0-9a-f]{32}\z') {
            throw [InvalidOperationException]::new(
                'The control resource group does not contain a valid authoritative avm-generation tag.'
            )
        }
        if (-not [string]::IsNullOrEmpty($ExpectedGeneration) -and
            $fixtureGeneration -cne $ExpectedGeneration) {
            throw [InvalidOperationException]::new(
                'The supplied avm-generation does not match the authoritative control resource-group tag.'
            )
        }
    }
    $storageInFixtureResourceGroup =
        $target.SubscriptionId -ieq $target.FixtureSubscriptionId -and
        $target.StorageAccountResourceGroupName -ieq $target.FixtureResourceGroupName
    if ($fixture -and $target.SubscriptionId -ieq $target.FixtureSubscriptionId -and (
            [string]::IsNullOrWhiteSpace($ownedGroups) -or
            @($ownedGroups.Split(';') | Where-Object {
                    $_ -ieq $target.StorageAccountResourceGroupName
                }).Count -gt 0
        )) {
        throw [InvalidOperationException]::new(
            'The lock storage resource group must be explicitly excluded from BRM avm-owned-groups.'
        )
    }

    $snapshot = Get-AzureLocalLockSnapshot -Target $target -ProcessInvoker $ProcessInvoker
    if ($Operation -ceq 'status') {
        if (-not $snapshot.Exists) {
            return [pscustomobject]@{
                State = 'missing'; Acquired = $false; OwnerHash = ''; Generation = ''; UpdatedAtUtc = ''
                FixtureExists = $fixture; FixtureGeneration = $fixtureGeneration
            }
        }
        return [pscustomobject]@{
            State = $snapshot.Record['state']; Acquired = $snapshot.Record['state'] -ceq 'leased'
            OwnerHash = $snapshot.Record['ownerHash']; Generation = $snapshot.Record['generation']
            UpdatedAtUtc = $snapshot.Record['updatedAtUtc']; FixtureExists = $fixture
            FixtureGeneration = $fixtureGeneration
        }
    }

    if ($Operation -ceq 'acquire') {
        if ([string]::IsNullOrEmpty($ownerHash)) {
            throw [ArgumentException]::new('acquire requires ownerHash.')
        }
        if ($Mode -ceq 'consumer' -and [string]::IsNullOrEmpty($ExpectedGeneration)) {
            throw [ArgumentException]::new('consumer acquire requires the authoritative avm-generation value.')
        }
        if ($AllowUninitialized -and (
                -not [string]::IsNullOrEmpty($ExpectedGeneration) -or
                -not [string]::IsNullOrEmpty($fixtureGeneration) -or
                $fixture -and -not $storageInFixtureResourceGroup
            )) {
            throw [ArgumentException]::new(
                'allowUninitialized requires no authoritative generation and an explicitly persistent control-group store.'
            )
        }
        if ($fixture -and [string]::IsNullOrEmpty($ExpectedGeneration) -and -not $AllowUninitialized) {
            throw [ArgumentException]::new('Acquiring an existing fixture requires the authoritative avm-generation value.')
        }
        if (-not $fixture -and -not $AllowUninitialized) {
            throw [InvalidOperationException]::new('The control resource group is absent; acquire requires allowUninitialized for lifecycle prepare.')
        }
        if ($RefreshGeneration -and $Mode -cne 'lifecycle') {
            throw [ArgumentException]::new('Only lifecycle acquire may refresh a lock generation.')
        }
        if ($snapshot.Exists -and $snapshot.Record['state'] -ceq 'leased') {
            if ($snapshot.Record['ownerHash'] -cne $ownerHash) {
                throw [InvalidOperationException]::new('The Azure Local environment is acquired by a different owner.')
            }
            if ($snapshot.Record['generation'] -cne $ExpectedGeneration) {
                if (-not $RefreshGeneration) {
                    throw [InvalidOperationException]::new('The Azure Local lock generation is stale for the same owner; explicit lifecycle refresh is required.')
                }
                $acquiredAt = [datetime]::Parse(
                    $snapshot.Record['acquiredAtUtc'], [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
                $record = New-AzureLocalLockRecord -State leased -OwnerHash $ownerHash `
                    -Generation $ExpectedGeneration -AcquiredAt $acquiredAt
                $snapshot = Set-AzureLocalLockSnapshot -Target $target -Record $record `
                    -Current $snapshot -ProcessInvoker $ProcessInvoker
            }
        }
        elseif (-not $snapshot.Exists -or $snapshot.Record['state'] -ceq 'released') {
            $record = New-AzureLocalLockRecord -State leased -OwnerHash $ownerHash -Generation $ExpectedGeneration
            $snapshot = Set-AzureLocalLockSnapshot -Target $target -Record $record `
                -Current $snapshot -ProcessInvoker $ProcessInvoker
        }
        return [pscustomobject]@{
            State = 'leased'; Acquired = $true; OwnerHash = $ownerHash
            Generation = $snapshot.Record['generation']; UpdatedAtUtc = $snapshot.Record['updatedAtUtc']
            FixtureExists = $fixture; FixtureGeneration = $fixtureGeneration
        }
    }

    if ($Operation -ceq 'release') {
        if ([string]::IsNullOrEmpty($ownerHash)) {
            throw [ArgumentException]::new('release requires ownerHash.')
        }
        if (-not $CleanupConfirmed) {
            throw [InvalidOperationException]::new('release requires independently verified cleanupConfirmed=true.')
        }
        if (-not $snapshot.Exists) {
            throw [InvalidOperationException]::new('release requires an existing lock record.')
        }
        if ($snapshot.Record['state'] -ceq 'released' -and
            $snapshot.Record['ownerHash'] -ceq $ownerHash -and
            $snapshot.Record['generation'] -ceq $ExpectedGeneration) {
            return [pscustomobject]@{
                State = 'released'; Acquired = $false; OwnerHash = $ownerHash
                Generation = $ExpectedGeneration; UpdatedAtUtc = $snapshot.Record['updatedAtUtc']
                FixtureExists = $fixture; FixtureGeneration = $fixtureGeneration
            }
        }
        if ($snapshot.Record['state'] -cne 'leased' -or
            $snapshot.Record['ownerHash'] -cne $ownerHash -or
            $snapshot.Record['generation'] -cne $ExpectedGeneration) {
            throw [InvalidOperationException]::new('release owner and generation must exactly match the acquired lock record.')
        }
        $acquiredAt = [datetime]::Parse(
            $snapshot.Record['acquiredAtUtc'], [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        $record = New-AzureLocalLockRecord -State released -OwnerHash $ownerHash `
            -Generation $ExpectedGeneration -AcquiredAt $acquiredAt
        $snapshot = Set-AzureLocalLockSnapshot -Target $target -Record $record `
            -Current $snapshot -ProcessInvoker $ProcessInvoker
        return [pscustomobject]@{
            State = 'released'; Acquired = $false; OwnerHash = $ownerHash
            Generation = $ExpectedGeneration; UpdatedAtUtc = $snapshot.Record['updatedAtUtc']
            FixtureExists = $fixture; FixtureGeneration = $fixtureGeneration
        }
    }

    if (-not $OwnerInactiveConfirmed -or
        $ExpectedOwnerHash -cnotmatch '\A[0-9a-f]{64}\z' -or
        [string]::IsNullOrWhiteSpace($RecoveryReason) -or $RecoveryReason.Length -gt 1024 -or
        $RecoveryReason -match '[\x00-\x1f\x7f]') {
        throw [ArgumentException]::new(
            'recover requires ownerInactiveConfirmed=true, the exact expected owner hash, and a nonempty safe reason.'
        )
    }
    if (-not $snapshot.Exists -or $snapshot.Record['state'] -cne 'leased' -or
        $snapshot.Record['ownerHash'] -cne $ExpectedOwnerHash -or
        $snapshot.Record['generation'] -cne $ExpectedGeneration) {
        throw [InvalidOperationException]::new('recover owner and generation must exactly match the acquired lock record.')
    }
    $acquiredAt = [datetime]::Parse(
        $snapshot.Record['acquiredAtUtc'], [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    $record = New-AzureLocalLockRecord -State released -OwnerHash $ExpectedOwnerHash `
        -Generation $ExpectedGeneration -AcquiredAt $acquiredAt -RecoveryReason $RecoveryReason
    $snapshot = Set-AzureLocalLockSnapshot -Target $target -Record $record `
        -Current $snapshot -ProcessInvoker $ProcessInvoker
    return [pscustomobject]@{
        State = 'released'; Acquired = $false; OwnerHash = $ExpectedOwnerHash
        Generation = $ExpectedGeneration; UpdatedAtUtc = $snapshot.Record['updatedAtUtc']
        FixtureExists = $fixture; FixtureGeneration = $fixtureGeneration
    }
}

if ($Execute) {
    if ($env:GITHUB_ACTIONS -cne 'true' -or [string]::IsNullOrEmpty($env:GITHUB_OUTPUT)) {
        throw [InvalidOperationException]::new('The Azure Local lock action must run inside GitHub Actions with GITHUB_OUTPUT.')
    }
    $result = Invoke-AzureLocalEnvironmentLease `
        -Operation $env:AVM_AZURE_LOCAL_OPERATION `
        -StorageAccountResourceId $env:AVM_AZURE_LOCAL_STORAGE_ACCOUNT_RESOURCE_ID `
        -FixtureResourceGroupId $env:AVM_AZURE_LOCAL_FIXTURE_RESOURCE_GROUP_ID `
        -ContainerName $env:AVM_AZURE_LOCAL_CONTAINER_NAME `
        -BlobName $env:AVM_AZURE_LOCAL_BLOB_NAME `
        -OwnerHash $env:AVM_AZURE_LOCAL_OWNER_HASH `
        -ExpectedGeneration $env:AVM_AZURE_LOCAL_EXPECTED_GENERATION `
        -Mode $env:AVM_AZURE_LOCAL_MODE `
        -RefreshGeneration (ConvertTo-AzureLocalBoolean -Name 'refresh-generation' -Value $env:AVM_AZURE_LOCAL_REFRESH_GENERATION) `
        -AllowUninitialized (ConvertTo-AzureLocalBoolean -Name 'allow-uninitialized' -Value $env:AVM_AZURE_LOCAL_ALLOW_UNINITIALIZED) `
        -CleanupConfirmed (ConvertTo-AzureLocalBoolean -Name 'cleanup-confirmed' -Value $env:AVM_AZURE_LOCAL_CLEANUP_CONFIRMED) `
        -ExpectedOwnerHash $env:AVM_AZURE_LOCAL_EXPECTED_OWNER_HASH `
        -OwnerInactiveConfirmed (ConvertTo-AzureLocalBoolean -Name 'owner-inactive-confirmed' -Value $env:AVM_AZURE_LOCAL_OWNER_INACTIVE_CONFIRMED) `
        -RecoveryReason $env:AVM_AZURE_LOCAL_RECOVERY_REASON
    foreach ($output in @(
            @{ Name = 'state'; Value = $result.State },
            @{ Name = 'acquired'; Value = $result.Acquired.ToString().ToLowerInvariant() },
            @{ Name = 'ownerHash'; Value = $result.OwnerHash },
            @{ Name = 'generation'; Value = $result.Generation },
            @{ Name = 'updatedAtUtc'; Value = $result.UpdatedAtUtc },
            @{ Name = 'fixtureExists'; Value = $result.FixtureExists.ToString().ToLowerInvariant() },
            @{ Name = 'fixtureGeneration'; Value = $result.FixtureGeneration }
        )) {
        "$($output.Name)=$($output.Value)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
}
