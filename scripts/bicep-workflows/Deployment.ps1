. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-AvmWorkflowSubscriptions {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $PoolJson,
        [AllowEmptyString()] [string] $FallbackSubscriptionId
    )

    if ([string]::IsNullOrEmpty($PoolJson)) {
        $subscriptions = @(@{ id = $FallbackSubscriptionId; name = 'Configured subscription 1' })
    }
    else {
        try { $subscriptions = ConvertFrom-Json -InputObject $PoolJson -AsHashtable -NoEnumerate }
        catch { throw [ArgumentException]::new('The configured subscription pool must be a JSON array of id/name objects.') }
        if ($subscriptions -isnot [array] -or $subscriptions.Count -eq 0) {
            throw [ArgumentException]::new('The configured subscription pool must be a nonempty JSON array.')
        }
    }
    for ($index = 0; $index -lt $subscriptions.Count; $index++) {
        $entry = $subscriptions[$index]
        $id = [guid]::Empty
        if ($entry -isnot [Collections.IDictionary] -or $entry['id'] -isnot [string] -or
            -not [guid]::TryParseExact($entry.id, 'D', [ref]$id) -or $id -eq [guid]::Empty) {
            throw [ArgumentException]::new('Each configured subscription must have a nonempty GUID id.')
        }
        if ($entry['name'] -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.name) -or
            $entry.name -match '[\x00-\x1f]') {
            throw [ArgumentException]::new('Each configured subscription must have a nonempty, single-line name.')
        }
        [pscustomobject]@{
            id = $id.ToString('D')
            name = $entry.name
            index = $index
            key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($id.ToString('D')))).ToLowerInvariant()
        }
    }
}

function Test-AvmWorkflowSharedScope {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [Collections.IDictionary] $Template)

    if ($Template['$schema'] -match '/(?:managementGroup|tenant)DeploymentTemplate\.json#?$') { return $true }
    $resources = if ($Template['resources'] -is [Collections.IDictionary]) {
        @($Template.resources.Values)
    }
    else { @($Template['resources']) }
    foreach ($resource in $resources) {
        if ($null -eq $resource) { continue }
        if ($resource -isnot [Collections.IDictionary]) {
            throw [ArgumentException]::new('Compiled deployment resources must be objects.')
        }
        if ($resource['type'] -ieq 'Microsoft.Resources/deployments') {
            $properties = $resource['properties']
            if ($properties -isnot [Collections.IDictionary]) {
                throw [ArgumentException]::new('Compiled nested deployments must have properties.')
            }
            if ($properties['templateLink'] -or $properties['template'] -is [string]) { return $true }
            if ($properties['template'] -is [Collections.IDictionary] -and
                (Test-AvmWorkflowSharedScope -Template $properties.template)) { return $true }
        }
        if ($resource['resources'] -and (Test-AvmWorkflowSharedScope -Template @{ resources = $resource.resources })) {
            return $true
        }
    }
    return $false
}

function Get-AvmWorkflowDeploymentMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $TestFiles,
        [string] $PoolJson,
        [string] $FallbackSubscriptionId,
        [ValidateRange(0, 2147483647)] [int] $RandomSeed = 0,
        [switch] $DisplaySubscriptionNames
    )

    $active = @($TestFiles | Where-Object { -not (ConvertTo-AvmWorkflowBoolean -Value $_.e2eIgnore) })
    $shared = $false
    $subscriptions = @()
    if ($active.Count -gt 0) {
        $subscriptions = @(Get-AvmWorkflowSubscriptions -PoolJson $PoolJson -FallbackSubscriptionId $FallbackSubscriptionId |
                Get-Random -Shuffle -SetSeed $RandomSeed)
        $tool = Get-AvmTool -Name bicep -SkipModuleVersionCheck
        if ($tool.Status -ne 'installed') { throw [InvalidOperationException]::new('The managed Bicep compiler is not installed.') }
        foreach ($test in $active) {
            $path = Resolve-AvmWorkflowPath -Root $Root -RelativePath "$ModulePath/$($test.path)"
            $result = Invoke-AvmWorkflowProcess -FilePath $tool.Path -ArgumentList @('build', $path, '--stdout') -WorkingDirectory $Root
            $template = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable
            if (Test-AvmWorkflowSharedScope -Template $template) { $shared = $true }
        }
    }
    $moduleKey = $ModulePath.Replace('\', '/').Trim('/').ToLowerInvariant()
    $matrix = @(for ($index = 0; $index -lt $TestFiles.Count; $index++) {
            $test = $TestFiles[$index]
            if ($test.path -isnot [string] -or $test.name -isnot [string] -or
                [string]::IsNullOrWhiteSpace($test.name) -or $test.name -match '[\x00-\x1f]') {
                throw [ArgumentException]::new('Every deployment test must contain a path and a single-line name.')
            }
            $ignored = ConvertTo-AvmWorkflowBoolean -Value $test.e2eIgnore
            $entry = @{
                path = $test.path; name = $test.name; e2eIgnore = $ignored
                subscriptionIndex = ''; subscriptionKey = ''
                subscriptionName = 'Deployment disabled'
                concurrencyGroup = "avm-deploy-$moduleKey-ignored-$([guid]::NewGuid().ToString('N'))"
            }
            if (-not $ignored) {
                $selected = $subscriptions[$index % $subscriptions.Count]
                $entry.subscriptionIndex = $selected.index
                $entry.subscriptionKey = $selected.key
                $entry.subscriptionName = if ($DisplaySubscriptionNames) { $selected.name } else { "Configured subscription $($selected.index + 1)" }
                $entry.concurrencyGroup = "avm-deploy-$moduleKey-$($selected.key)"
            }
            $entry
        })
    return @{
        deploymentMatrix = ConvertTo-Json -InputObject $matrix -Depth 10 -Compress
        sharedScope = $shared.ToString().ToLowerInvariant()
    }
}

function Get-AvmWorkflowAuthentication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [Collections.IDictionary] $TestCase,
        [string] $PoolJson,
        [string] $FallbackSubscriptionId,
        [string] $ClientId,
        [string] $TenantId,
        [string] $Credentials
    )

    $pool = @(Get-AvmWorkflowSubscriptions -PoolJson $PoolJson -FallbackSubscriptionId $FallbackSubscriptionId)
    $index = 0
    if (-not [int]::TryParse([string]$TestCase['subscriptionIndex'], [ref]$index) -or
        $index -lt 0 -or $index -ge $pool.Count -or
        [string]$TestCase['subscriptionKey'] -cnotmatch '^[0-9a-f]{64}$' -or
        $pool[$index].key -cne [string]$TestCase.subscriptionKey) {
        throw [ArgumentException]::new('The selected subscription no longer matches the original pool index and digest. Rerun selection.')
    }
    $null = Resolve-AvmWorkflowPath -Root $Root -RelativePath "$ModulePath/$($TestCase.path)"
    $exceptionsPath = Resolve-AvmWorkflowPath -Root $Root -RelativePath '.oidc-exceptions.json'
    $exceptions = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $exceptionsPath -Raw) -NoEnumerate
    if ($exceptions -isnot [array]) { throw [ArgumentException]::new('.oidc-exceptions.json must be a JSON string array.') }
    $useSecret = $false
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($exception in $exceptions) {
        if ($exception -isnot [string] -or $exception -cnotmatch '^avm/(res|ptn|utl)/[a-z0-9-]+/[a-z0-9-]+$' -or
            -not $seen.Add($exception)) {
            throw [ArgumentException]::new('.oidc-exceptions.json must contain unique, exact top-level module paths.')
        }
        if ($ModulePath -ceq $exception -or $ModulePath.StartsWith("$exception/", [StringComparison]::Ordinal)) {
            $useSecret = $true
        }
    }
    $credentialJson = ''
    if ($useSecret) {
        try { $credentialObject = ConvertFrom-Json -InputObject $Credentials -AsHashtable }
        catch { throw [ArgumentException]::new('This module requires valid AZURE_CREDENTIALS JSON.') }
        foreach ($field in @('clientId', 'clientSecret', 'tenantId')) {
            if ($credentialObject -isnot [Collections.IDictionary] -or $credentialObject[$field] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($credentialObject[$field])) {
                throw [ArgumentException]::new('AZURE_CREDENTIALS requires nonempty clientId, clientSecret and tenantId strings.')
            }
        }
        if (-not [string]::IsNullOrEmpty($TenantId) -and $TenantId -ine $credentialObject.tenantId) {
            throw [ArgumentException]::new('AZURE_CREDENTIALS tenantId does not match the configured validation tenant.')
        }
        $TenantId = $credentialObject.tenantId
        $ClientId = $credentialObject.clientId
        $credentialObject.subscriptionId = $pool[$index].id
        $credentialJson = ConvertTo-Json -InputObject $credentialObject -Compress -Depth 10
    }
    if ([string]::IsNullOrWhiteSpace($ClientId) -or [string]::IsNullOrWhiteSpace($TenantId) -or
        $ClientId -match '[\x00-\x1f]' -or $TenantId -match '[\x00-\x1f]') {
        throw [ArgumentException]::new('Validation client and tenant identifiers must be configured; ordinary modules do not fall back to secret authentication.')
    }
    return @{
        subscriptionId = $pool[$index].id
        tenantId = $TenantId
        clientId = $ClientId
        useSecret = $useSecret.ToString().ToLowerInvariant()
        credentials = $credentialJson
    }
}

function Confirm-AvmWorkflowAzureContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $TenantId
    )

    $context = Get-AzContext -ErrorAction Stop
    $tenant = [guid]::Empty
    $configured = [guid]::Empty
    if ($null -eq $context -or $context.Subscription.Id -ine $SubscriptionId -or
        -not [guid]::TryParseExact($context.Tenant.Id, 'D', [ref]$tenant) -or $tenant -eq [guid]::Empty -or
        ([guid]::TryParseExact($TenantId, 'D', [ref]$configured) -and $configured -ne $tenant)) {
        throw [InvalidOperationException]::new('The Azure PowerShell context does not match the selected subscription and tenant.')
    }
    return $tenant.ToString('D')
}
