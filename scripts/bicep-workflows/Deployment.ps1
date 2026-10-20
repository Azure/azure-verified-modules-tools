. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot '..' '..' 'repository-management' 'shared' 'TestTenant.ps1')

function Get-AvmWorkflowModuleIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [AllowEmptyString()] [string] $ModuleClientIds,
        [AllowEmptyString()] [string] $TenantId
    )

    if ([string]::IsNullOrWhiteSpace($ModuleClientIds)) {
        throw [ArgumentException]::new('VALIDATE_MODULE_CLIENT_IDS must contain the published module client-ID mapping; no shared identity fallback is supported.')
    }
    try {
        $mapping = ConvertFrom-AvmTestTenantJson -Json $ModuleClientIds
        if ($mapping -isnot [Collections.IDictionary]) {
            throw [ArgumentException]::new('The module client-ID mapping must be a JSON object.')
        }
        $null = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $mapping
    }
    catch [ArgumentException] {
        throw [ArgumentException]::new('VALIDATE_MODULE_CLIENT_IDS is invalid; require unique canonical root paths and distinct nonempty client GUIDs.', $_.Exception)
    }
    $path = Resolve-AvmWorkflowPath -Root $Root -RelativePath $ModulePath
    $relative = $ModulePath.Replace('\', '/')
    if ([IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root), $path).Replace('\', '/') -cne $relative) {
        throw [ArgumentException]::new('The module path must be canonical without empty or current-directory segments.')
    }
    $roots = @($mapping.Keys | Where-Object {
            $relative -ceq $_ -or $relative.StartsWith("$_/", [StringComparison]::Ordinal)
        })
    if ($roots.Count -ne 1) {
        throw [ArgumentException]::new("VALIDATE_MODULE_CLIENT_IDS must contain exactly one canonical root for '$relative'.")
    }
    $tenant = [guid]::Empty
    if (-not [guid]::TryParseExact($TenantId, 'D', [ref]$tenant) -or $tenant -eq [guid]::Empty) {
        throw [ArgumentException]::new('VALIDATE_TENANT_ID must be the nonempty GUID published with the module identity mapping.')
    }
    $client = ([guid]$mapping[$roots[0]]).ToString('D')
    return @{
        moduleRoot = $roots[0]
        clientId = $client
        tenantId = $tenant.ToString('D')
        identityKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes("$($roots[0])|$client|$($tenant.ToString('D'))"))).ToLowerInvariant()
    }
}

function Select-AvmWorkflowSubscription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $Example,
        [AllowEmptyString()] [string] $PoolJson,
        [AllowEmptyString()] [string] $FallbackSubscriptionId,
        [ValidateRange(0, 2147483647)] [int] $RandomSeed = 0,
        [ValidateRange(0, 2147483647)] [int] $CaseIndex = 0
    )

    if ([string]::IsNullOrEmpty($PoolJson)) {
        $PoolJson = ConvertTo-Json -InputObject @(@{ id = $FallbackSubscriptionId; name = 'Configured subscription 1' }) -Compress
    }
    $selected = @(Select-AvmTestSubscription -Path $Root -ModulePath $ModulePath -Example $Example `
            -TestSubscriptionIds $PoolJson -RandomSeed $RandomSeed -CaseIndex $CaseIndex -SkipModuleVersionCheck)
    if ($selected.Count -ne 1) {
        throw [InvalidOperationException]::new('Native subscription selection must return exactly one eligible target.')
    }
    if ($selected[0].Tag -cne 'General') {
        throw [InvalidOperationException]::new('Reserved test subscriptions require the registry-local prepared environment lifecycle; shared native deployment cannot authenticate or execute this case.')
    }
    $ownerPath = Resolve-AvmWorkflowPath -Root $Root -RelativePath $selected[0].ModulePath
    $null = Get-AvmModuleContext -Path $ownerPath -Ecosystem bicep -SkipModuleVersionCheck
    return $selected[0]
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
        [string] $ModuleClientIds,
        [string] $TenantId,
        [ValidateRange(0, 2147483647)] [int] $RandomSeed = 0,
        [switch] $DisplaySubscriptionNames
    )

    $active = @($TestFiles | Where-Object { -not (ConvertTo-AvmWorkflowBoolean -Value $_.e2eIgnore) })
    $shared = $false
    $selections = @{}
    $identity = $null
    if ($active.Count -gt 0) {
        $identity = Get-AvmWorkflowModuleIdentity -Root $Root -ModulePath $ModulePath `
            -ModuleClientIds $ModuleClientIds -TenantId $TenantId
        for ($index = 0; $index -lt $TestFiles.Count; $index++) {
            $test = $TestFiles[$index]
            if (ConvertTo-AvmWorkflowBoolean -Value $test.e2eIgnore) { continue }
            $selections[$index] = Select-AvmWorkflowSubscription -Root $Root -ModulePath $ModulePath `
                -Example $test.path -PoolJson $PoolJson -FallbackSubscriptionId $FallbackSubscriptionId `
                -RandomSeed $RandomSeed -CaseIndex $index
        }
        $module = Resolve-AvmWorkflowPath -Root $Root -RelativePath $ModulePath
        $tool = Get-AvmTool -Name bicep -Path $module -SkipModuleVersionCheck
        if ($tool.Status -ceq 'not-installed') {
            $null = Install-AvmTool -Name bicep -Path $module -SkipModuleVersionCheck -Confirm:$false
            $tool = Get-AvmTool -Name bicep -Path $module -SkipModuleVersionCheck
        }
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
                selectionSeed = ''; caseIndex = ''; subscriptionModulePath = ''
                identityKey = ''
                subscriptionName = 'Deployment disabled'
                concurrencyGroup = "avm-deploy-$moduleKey-ignored-$([guid]::NewGuid().ToString('N'))"
            }
            if (-not $ignored) {
                $selected = $selections[$index]
                $entry.subscriptionIndex = $selected.Index
                $entry.subscriptionKey = $selected.Key
                $entry.selectionSeed = $RandomSeed
                $entry.caseIndex = $index
                $entry.subscriptionModulePath = $selected.ModulePath
                $entry.identityKey = $identity.identityKey
                $entry.subscriptionName = if ($DisplaySubscriptionNames) { $selected.Name } else { "Configured subscription $($selected.Index + 1)" }
                $entry.concurrencyGroup = "avm-deploy-$moduleKey-$($selected.Key)"
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
        [string] $ModuleClientIds,
        [string] $TenantId
    )

    $identity = Get-AvmWorkflowModuleIdentity -Root $Root -ModulePath $ModulePath `
        -ModuleClientIds $ModuleClientIds -TenantId $TenantId
    if ([string]$TestCase['identityKey'] -cnotmatch '^[0-9a-f]{64}$' -or
        $TestCase['identityKey'] -cne $identity.identityKey) {
        throw [ArgumentException]::new('The selected module identity no longer matches its root, client and tenant. Rerun selection.')
    }
    $seed = 0
    $caseIndex = 0
    if (-not [int]::TryParse([string]$TestCase['selectionSeed'], [ref]$seed) -or $seed -lt 0 -or
        -not [int]::TryParse([string]$TestCase['caseIndex'], [ref]$caseIndex) -or $caseIndex -lt 0) {
        throw [ArgumentException]::new('The selected subscription is missing its nonnegative selection seed and case index. Rerun selection.')
    }
    $selected = Select-AvmWorkflowSubscription -Root $Root -ModulePath $ModulePath -Example $TestCase.path `
        -PoolJson $PoolJson -FallbackSubscriptionId $FallbackSubscriptionId -RandomSeed $seed -CaseIndex $caseIndex
    $index = 0
    if (-not [int]::TryParse([string]$TestCase['subscriptionIndex'], [ref]$index) -or
        $index -lt 0 -or $index -ne $selected.Index -or
        [string]$TestCase['subscriptionKey'] -cnotmatch '^[0-9a-f]{64}$' -or
        $selected.Key -cne [string]$TestCase.subscriptionKey -or
        $selected.ModulePath -cne [string]$TestCase['subscriptionModulePath']) {
        throw [ArgumentException]::new('The selected subscription no longer matches the original pool index and digest. Rerun selection.')
    }
    $testPath = Resolve-AvmWorkflowPath -Root $Root -RelativePath "$ModulePath/$($TestCase.path)"
    $ownerPath = Resolve-AvmWorkflowPath -Root $Root -RelativePath $selected.ModulePath
    $example = [IO.Path]::GetRelativePath($ownerPath, $testPath).Replace('\', '/')
    $null = Resolve-AvmWorkflowPath -Root $ownerPath -RelativePath $example
    return @{
        subscriptionId = $selected.SubscriptionId
        tenantId = $identity.tenantId
        clientId = $identity.clientId
        modulePath = $selected.ModulePath
        example = $example
    }
}

function Confirm-AvmWorkflowAzureContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $ClientId
    )

    $context = Get-AzContext -ErrorAction Stop
    $tenant = [guid]::Empty
    $configured = [guid]::Empty
    if ($null -eq $context -or $context.Subscription.Id -ine $SubscriptionId -or
        -not [guid]::TryParseExact($context.Tenant.Id, 'D', [ref]$tenant) -or $tenant -eq [guid]::Empty -or
        -not [guid]::TryParseExact($TenantId, 'D', [ref]$configured) -or $configured -ne $tenant -or
        $context.Account.Id -ine $ClientId -or $context.Account.Type -ine 'ServicePrincipal' -or
        $context.Environment.Name -cne 'AzureCloud') {
        throw [InvalidOperationException]::new('The Azure PowerShell context does not match the selected module client, tenant, subscription and cloud.')
    }
    return $tenant.ToString('D')
}
