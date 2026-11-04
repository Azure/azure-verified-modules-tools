#Requires -Version 7.4

function Get-AvmRetainedEvidencePolicy {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        BundleSha256   = '25460d6003abebfe56288dadebf89e040f4f57f3698452909f3368b625a7e6c7'
        BundleLength   = 15052
        ScopeSha256    = 'b1c676e69fb26a59b033d0d89346f46dd6f530c56d8183f7e4aadb2ac374373d'
        IdentitySha256 = '8ccd551acfe8d6c87d2514716cf2ab85254138c4f3cd5ab5dd4dc0786cc1b987'
        ProfileId      = 'brm-original41453393060-attempt1-readonly11plusmg'
        Subject        = 'repository_owner_id:6844498:repository_id:447791597:environment:avm-validation'
        MaximumPages   = 5
    }
}

function Get-AvmEvidenceHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [byte[]] $Bytes)

    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function ConvertFrom-AvmEvidenceJson {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Text,
        [int] $MaximumLength = 65536
    )

    if ($Text.Length -gt $MaximumLength) {
        throw [IO.InvalidDataException]::new('Evidence JSON exceeds its size bound.')
    }
    $document = $null
    try {
        $options = [Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 32
        $document = [Text.Json.JsonDocument]::Parse($Text, $options)
        $pending = [Collections.Generic.Stack[Text.Json.JsonElement]]::new()
        $pending.Push($document.RootElement)
        while ($pending.Count -gt 0) {
            $element = $pending.Pop()
            if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) {
                        throw [IO.InvalidDataException]::new('Duplicate JSON property.')
                    }
                    $pending.Push($property.Value)
                }
            }
            elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($item in $element.EnumerateArray()) {
                    $pending.Push($item)
                }
            }
        }
        return ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 32 -ErrorAction Stop
    }
    catch {
        throw [IO.InvalidDataException]::new('Evidence JSON is invalid or contains duplicate properties.')
    }
    finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }
}

function ConvertFrom-AvmEvidencePayload {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Base64,
        [Parameter(Mandatory)] [string] $ExpectedSha256
    )

    if ($Base64.Length -gt 45000 -or $ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw [IO.InvalidDataException]::new('Evidence payload exceeds its bound or lacks a valid digest.')
    }
    try {
        $bytes = [Convert]::FromBase64String($Base64)
        if ([Convert]::ToBase64String($bytes) -cne $Base64) {
            throw [IO.InvalidDataException]::new('Evidence payload is not canonical base64.')
        }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    catch {
        throw [IO.InvalidDataException]::new('Evidence payload is not valid base64 UTF-8.')
    }
    if ((Get-AvmEvidenceHash -Bytes $bytes) -cne $ExpectedSha256) {
        throw [IO.InvalidDataException]::new('Evidence payload does not match the admitted digest.')
    }
    return ConvertFrom-AvmEvidenceJson -Text $text
}

function Get-AvmRetainedEvidenceBundle {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $BundleBase64,
        [Parameter(Mandatory)] [string] $BundleSha256
    )

    $policy = Get-AvmRetainedEvidencePolicy
    if ($BundleSha256 -cne $policy.BundleSha256) {
        throw [IO.InvalidDataException]::new('The caller cannot change the tools-owned admitted bundle digest.')
    }
    if ($BundleBase64.Length -ne [int]([math]::Ceiling($policy.BundleLength / 3.0) * 4)) {
        throw [IO.InvalidDataException]::new('Evidence bundle length differs from the admitted bytes.')
    }
    $bundle = ConvertFrom-AvmEvidencePayload -Base64 $BundleBase64 -ExpectedSha256 $policy.BundleSha256
    if ($bundle.schemaVersion -ne 1 -or $bundle.profileId -cne $policy.ProfileId -or
        $bundle.actualHistoricalSubject -cne $policy.Subject -or $bundle.baseReadTargets -ne 25 -or
        $bundle.additional73ScopesAdmitted -ne $false -or
        $bundle.scope.sha256 -cne $policy.ScopeSha256 -or
        $bundle.identityGates.sha256 -cne $policy.IdentitySha256 -or
        $bundle.scope.encoding -cne 'base64' -or $bundle.identityGates.encoding -cne 'base64' -or
        [Convert]::FromBase64String($bundle.scope.data).Length -ne $bundle.scope.length -or
        [Convert]::FromBase64String($bundle.identityGates.data).Length -ne $bundle.identityGates.length) {
        throw [IO.InvalidDataException]::new('Evidence bundle does not describe the admitted diagnostic.')
    }
    $scope = ConvertFrom-AvmEvidencePayload -Base64 $bundle.scope.data -ExpectedSha256 $policy.ScopeSha256
    $identities = ConvertFrom-AvmEvidencePayload -Base64 $bundle.identityGates.data -ExpectedSha256 $policy.IdentitySha256
    if (@($scope.cases).Count -ne 11 -or @($identities.identities).Count -ne 6 -or
        $scope.baseReadTargets -ne 25 -or $scope.additional73Admitted -ne $false) {
        throw [IO.InvalidDataException]::new('Evidence scope cardinality differs from the admitted profile.')
    }
    return @{ Scope = $scope; Identities = $identities; Sha256 = $policy.BundleSha256 }
}

function Get-AvmRetainedEvidenceSelection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Bundle,
        [Parameter(Mandatory)] [string] $CaseKey,
        [Parameter(Mandatory)] [string] $ModuleClientIds,
        [Parameter(Mandatory)] [string] $TenantId
    )

    $scope = $Bundle.Scope
    $selectedCases = @($scope.cases | Where-Object { "case-$($_.jobId)" -ceq $CaseKey })
    $managementGroup = $CaseKey -ceq "mg-$($scope.mg.jobId)"
    if ($managementGroup) {
        $case = $scope.mg
        $targets = @(
            @{ Id = $case.parentId; Kind = 'ManagementGroup'; ApiVersion = '2020-05-01' }
            @{ Id = $case.childId; Kind = 'ManagementGroup'; ApiVersion = '2020-05-01' }
            @{ Id = $case.deploymentId; Kind = 'Deployment'; ApiVersion = '2025-04-01' }
        )
    }
    elseif ($selectedCases.Count -eq 1) {
        $case = $selectedCases[0]
        if ($case.rootId -cnotmatch '^/subscriptions/[0-9a-f-]{36}/providers/Microsoft.Resources/deployments/[a-zA-Z0-9._()-]+$' -or
            $case.operationsId -cne "$($case.rootId)/operations" -or
            -not $case.rootId.StartsWith("/subscriptions/$($case.subscriptionId)/", [StringComparison]::Ordinal)) {
            throw [IO.InvalidDataException]::new('Admitted root identity is malformed.')
        }
        $targets = @(
            @{ Id = $case.rootId; Kind = 'Deployment'; ApiVersion = '2025-04-01' }
            @{ Id = $case.operationsId; Kind = 'Operations'; ApiVersion = '2025-04-01' }
        )
    }
    else {
        throw [IO.InvalidDataException]::new('Selected evidence leg is not admitted.')
    }
    $guid = [guid]::Empty
    foreach ($value in @($TenantId, $case.tenantId, $case.subscriptionId)) {
        if (-not [guid]::TryParseExact($value, 'D', [ref]$guid) -or $guid -eq [guid]::Empty) {
            throw [IO.InvalidDataException]::new('Evidence tenant or subscription is invalid.')
        }
    }
    if ($TenantId -cne $case.tenantId -or $case.tenantId -cne $scope.mg.tenantId) {
        throw [InvalidOperationException]::new('Configured tenant differs from the admitted TEST tenant.')
    }
    $map = ConvertFrom-AvmEvidenceJson -Text $ModuleClientIds
    $keys = @($map.Keys | Where-Object { $_ -ceq $case.modulePath })
    $gates = @($Bundle.Identities.identities | Where-Object { $_.modulePath -ceq $case.modulePath })
    if ($keys.Count -ne 1 -or $gates.Count -ne 1 -or
        -not [guid]::TryParseExact([string]$map[$keys[0]], 'D', [ref]$guid) -or $guid -eq [guid]::Empty) {
        throw [InvalidOperationException]::new('The exact admitted module client is unavailable; no fallback is permitted.')
    }
    $client = $guid.ToString('D')
    $fingerprint = Get-AvmEvidenceHash -Bytes ([Text.Encoding]::UTF8.GetBytes($client))
    if ($fingerprint -cne $gates[0].clientIdSha256) {
        throw [InvalidOperationException]::new('Configured module client differs from the admitted fingerprint.')
    }
    return @{
        CaseKey         = $CaseKey
        ModulePath      = $case.modulePath
        TenantId        = $case.tenantId
        SubscriptionId  = $case.subscriptionId
        ClientId        = $client
        ClientSha256    = $fingerprint
        Targets         = $targets
        ManagementGroup = $scope.mg
        OriginalCase    = $case
    }
}

function Get-AvmRetainedEvidenceAdmission {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $BundleBase64,
        [Parameter(Mandatory)] [string] $BundleSha256,
        [Parameter(Mandatory)] [string] $ExpectedCommit,
        [Parameter(Mandatory)] [string] $CallerCommit,
        [Parameter(Mandatory)] [string] $CallerRepository,
        [Parameter(Mandatory)] [string] $CallerEvent,
        [Parameter(Mandatory)] [string] $ToolsRef,
        [Parameter(Mandatory)] [string] $ToolsCommit,
        [Parameter(Mandatory)] [bool] $DiagnosticEnabled,
        [Parameter(Mandatory)] [bool] $RunE2E,
        [Parameter(Mandatory)] [string] $ModuleClientIds,
        [Parameter(Mandatory)] [string] $TenantId
    )

    if ($CallerRepository -cne 'Azure/bicep-registry-modules' -or $CallerEvent -cne 'workflow_dispatch' -or
        -not $DiagnosticEnabled -or $RunE2E -or $ExpectedCommit -cnotmatch '^[0-9a-f]{40}$' -or
        $CallerCommit -cne $ExpectedCommit -or $ToolsRef -cnotmatch '^[0-9a-f]{40}$' -or
        $ToolsCommit -cne $ToolsRef) {
        throw [InvalidOperationException]::new('Read-only evidence requires the exact approved manual caller and immutable tools checkout.')
    }
    $bundle = Get-AvmRetainedEvidenceBundle -BundleBase64 $BundleBase64 -BundleSha256 $BundleSha256
    $entries = @(
        foreach ($case in $bundle.Scope.cases) {
            @{ caseKey = "case-$($case.jobId)"; modulePath = $case.modulePath }
        }
        @{ caseKey = "mg-$($bundle.Scope.mg.jobId)"; modulePath = $bundle.Scope.mg.modulePath }
    )
    if (@($entries.caseKey | Select-Object -Unique).Count -ne 12) {
        throw [IO.InvalidDataException]::new('Evidence leg identities are not unique.')
    }
    foreach ($entry in $entries) {
        $null = Get-AvmRetainedEvidenceSelection -Bundle $bundle -CaseKey $entry.caseKey `
            -ModuleClientIds $ModuleClientIds -TenantId $TenantId
    }
    return @{ Bundle = $bundle; Matrix = @{ include = $entries } }
}

function Assert-AvmRetainedEvidenceContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [hashtable] $Selection)

    $context = Get-AzContext -ErrorAction Stop
    if ($null -eq $context) {
        throw [InvalidOperationException]::new('An authenticated CI Azure context is unavailable.')
    }
    $observation = @{
        tenantId       = $context.Tenant.Id
        subscriptionId = $context.Subscription.Id
        clientIdSha256 = if ($context.Account.Id) {
            Get-AvmEvidenceHash -Bytes ([Text.Encoding]::UTF8.GetBytes($context.Account.Id.ToLowerInvariant()))
        }
        else { $null }
        accountType    = $context.Account.Type
        cloud          = $context.Environment.Name
    }
    if ($null -eq $context -or $context.Tenant.Id -cne $Selection.TenantId -or
        $context.Subscription.Id -cne $Selection.SubscriptionId -or
        $context.Account.Type -ine 'ServicePrincipal' -or $context.Account.Id -ine $Selection.ClientId -or
        $context.Environment.Name -cne 'AzureCloud' -or
        $context.Environment.ResourceManagerUrl -cne 'https://management.azure.com/') {
        $exception = [InvalidOperationException]::new('Actual Azure principal, tenant, subscription or cloud differs from the admitted leg.')
        $exception.Data['ObservedContext'] = $observation
        throw $exception
    }
    return $observation
}

function Get-AvmRetainedEvidenceUri {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [hashtable] $Target,
        [string] $NextLink
    )

    $path = $Target.Id
    if ($path -cnotmatch '^/(subscriptions/[0-9a-f-]{36}/providers/Microsoft.Resources/deployments/[A-Za-z0-9._()-]+(/operations)?|providers/Microsoft.Management/managementGroups/[A-Za-z0-9._()-]+(/providers/Microsoft.Resources/deployments/[A-Za-z0-9._()-]+)?)$') {
        throw [IO.InvalidDataException]::new('Evidence target path is not a supported exact ARM read.')
    }
    $suffix = if ($Target.Kind -ceq 'ManagementGroup') { '&$expand=children' } else { '' }
    $initial = "https://management.azure.com${path}?api-version=$($Target.ApiVersion)$suffix"
    if ([string]::IsNullOrEmpty($NextLink)) {
        return $initial
    }
    $uri = $null
    if ($Target.Kind -cne 'Operations' -or $NextLink.Length -gt 8192 -or $NextLink -match '[\x00-\x20\\#]' -or
        -not [uri]::TryCreate($NextLink, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.Host -cne 'management.azure.com' -or
        -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.AbsolutePath -cne $path -or
        $NextLink -cnotmatch ('^https://management\.azure\.com' + [regex]::Escape($path) + '\?')) {
        throw [IO.InvalidDataException]::new('Operations pagination leaves the admitted exact ARM endpoint.')
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($pair in $uri.Query.TrimStart('?').Split('&')) {
        $parts = $pair.Split('=', 2)
        if ($parts.Count -ne 2 -or -not $seen.Add($parts[0]) -or
            $parts[0] -cnotin @('api-version', '$skiptoken', '$top') -or
            $parts[1] -cnotmatch '^[A-Za-z0-9%._~+-]{1,2048}$') {
            throw [IO.InvalidDataException]::new('Operations pagination query is not admitted.')
        }
        if ($parts[0] -ceq 'api-version' -and $parts[1] -cne $Target.ApiVersion) {
            throw [IO.InvalidDataException]::new('Operations pagination changed the API version.')
        }
        if ($parts[0] -ceq '$top' -and $parts[1] -notmatch '^[1-9][0-9]{0,2}$') {
            throw [IO.InvalidDataException]::new('Operations page size is invalid.')
        }
    }
    if (-not $seen.Contains('api-version')) {
        throw [IO.InvalidDataException]::new('Operations pagination omitted the API version.')
    }
    return $NextLink
}

function Select-AvmRetainedEvidenceResponse {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [hashtable] $Body,
        [Parameter(Mandatory)] [hashtable] $Target,
        [Parameter(Mandatory)] [hashtable] $Selection
    )

    if ($Target.Kind -ceq 'Operations') {
        if (-not $Body.Contains('value') -or $Body.value -isnot [array] -or $Body.value.Count -gt 1000) {
            throw [IO.InvalidDataException]::new('ARM operations response is invalid or exceeds its bound.')
        }
        $records = @($Body.value)
    }
    else {
        if ($Body.id -ine $Target.Id) {
            throw [IO.InvalidDataException]::new('ARM response identity differs from the requested record.')
        }
        $records = @($Body)
    }
    $observations = @(
        foreach ($record in $records) {
            $properties = $record.properties
            if ($properties -isnot [System.Collections.IDictionary]) {
                throw [IO.InvalidDataException]::new('ARM record properties are unavailable.')
            }
            if ($Target.Kind -ceq 'ManagementGroup') {
                if ($properties.tenantId -ine $Selection.TenantId) {
                    throw [IO.InvalidDataException]::new('Management group belongs to a different tenant.')
                }
                $parent = if ($properties.details -and $properties.details.parent) { $properties.details.parent.id } else { $null }
                if ($parent -and $parent -cnotmatch '^/providers/Microsoft.Management/managementGroups/[A-Za-z0-9._()-]+$') {
                    throw [IO.InvalidDataException]::new('Management group parent identity is invalid.')
                }
                @{
                    id                  = $Target.Id
                    tenantId            = $properties.tenantId
                    parentId            = $parent
                    childrenReturned    = $properties.Contains('children')
                    listedChildCount    = if ($properties.Contains('children')) { @($properties.children).Count } else { $null }
                    expectedChildListed = if ($properties.Contains('children')) {
                        @($properties.children | Where-Object { $_.id -ieq $Selection.ManagementGroup.childId }).Count -gt 0
                    }
                    else { $null }
                }
            }
            else {
                $state = [string]$properties.provisioningState
                if ($state -cnotin @('Accepted', 'Running', 'Ready', 'Creating', 'Updating', 'Deleting',
                        'NotSpecified', 'Succeeded', 'Failed', 'Canceled', 'Cancelled')) {
                    throw [IO.InvalidDataException]::new('ARM provisioning state is not recognized.')
                }
                $item = @{ provisioningState = $state }
                if ($Target.Kind -ceq 'Deployment') {
                    $item.id = $Target.Id
                }
                else {
                    $operationId = [string]$record.operationId
                    if ($operationId -cnotmatch '^[A-Fa-f0-9-]{1,64}$') {
                        throw [IO.InvalidDataException]::new('ARM operation identity is invalid.')
                    }
                    $item.operationId = $operationId
                    $targetId = if ($properties.targetResource) { [string]$properties.targetResource.id } else { '' }
                    if ($targetId) {
                        if ($targetId.Length -gt 2048 -or $targetId -cnotmatch '^/subscriptions/[0-9a-f-]{36}/(resourceGroups/[A-Za-z0-9._()-]+|((resourceGroups/[A-Za-z0-9._()-]+/)?providers/[A-Za-z0-9.]+(/[A-Za-z0-9._()-]+){2,20}))$') {
                            throw [IO.InvalidDataException]::new('ARM operation target identity is invalid.')
                        }
                        $item.targetResourceId = $targetId
                    }
                }
                $item
            }
        }
    )
    Write-Output -NoEnumerate -InputObject $observations
}

function Write-AvmRetainedEvidenceResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Result,
        [Parameter(Mandatory)] [string] $OutputPath
    )

    $directory = Split-Path -Parent $OutputPath
    $null = New-Item -ItemType Directory -Path $directory -Force
    $json = ($Result | ConvertTo-Json -Depth 16).ReplaceLineEndings("`n") + "`n"
    [IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
    $digest = Get-AvmEvidenceHash -Bytes ([IO.File]::ReadAllBytes($OutputPath))
    [IO.File]::WriteAllText("$OutputPath.sha256", "$digest`n", [Text.UTF8Encoding]::new($false))
}

function Invoke-AvmRetainedEvidenceRead {
    <#
    .SYNOPSIS
        Observe one digest-admitted retained TEST leg using exact ARM GETs only.
    .DESCRIPTION
        Revalidates the immutable bundle and existing module identity, checks the
        actual Azure context before every request, and retains sanitized partial
        evidence before raising an incomplete-read error. Never signs in, changes
        context, deploys, recovers or deletes Azure resources.
    .PARAMETER BundleBase64
        Canonical base64 of the independently admitted scope bundle.
    .PARAMETER BundleSha256
        SHA256 that must also match the tools-owned authority.
    .PARAMETER CaseKey
        One of the twelve admitted historical job keys.
    .PARAMETER ModuleClientIds
        Existing canonical module-to-client mapping, with no generic fallback.
    .PARAMETER TenantId
        Existing TEST tenant configuration; must match the admitted scope.
    .PARAMETER OutputPath
        Local sanitized JSON artifact path, with a matching SHA256 sidecar.
    .PARAMETER AuthenticationSucceeded
        Whether the separate existing CI OIDC login succeeded.
    .EXAMPLE
        Invoke-AvmRetainedEvidenceRead @admittedLeg
    .OUTPUTS
        System.Collections.Hashtable. Sanitized observations for one admitted leg.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $BundleBase64,
        [Parameter(Mandatory)] [string] $BundleSha256,
        [Parameter(Mandatory)] [string] $CaseKey,
        [Parameter(Mandatory)] [string] $ModuleClientIds,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $OutputPath,
        [bool] $AuthenticationSucceeded = $false
    )

    $result = @{
        schemaVersion = 1
        observedAtUtc = [datetime]::UtcNow.ToString('o')
        status        = 'Error'
        caseKey       = $CaseKey
        bundleSha256  = $BundleSha256
        context       = $null
        requests      = [Collections.Generic.List[object]]::new()
        failure       = $null
        limitations   = 'Point-in-time ARM record observations only; no resource absence, ownership clearance, cleanup completion, provider purge or mutation authority is inferred.'
    }
    $stage = 'bundle-admission'
    try {
        $bundle = Get-AvmRetainedEvidenceBundle -BundleBase64 $BundleBase64 -BundleSha256 $BundleSha256
        $stage = 'identity-admission'
        $selection = Get-AvmRetainedEvidenceSelection -Bundle $bundle -CaseKey $CaseKey `
            -ModuleClientIds $ModuleClientIds -TenantId $TenantId
        $result.modulePath = $selection.ModulePath
        $result.admittedTargetCount = $selection.Targets.Count
        $result.provenance = @{
            originalRun         = $bundle.Scope.originalRun
            originalAttempt     = $bundle.Scope.attempt
            originalHead        = $bundle.Scope.originalHead
            originalJobId       = $selection.OriginalCase.jobId
            originalArtifactId  = $selection.OriginalCase.artifactId
            sourceReceiptSha256 = if ($selection.OriginalCase.Contains('sourceReceiptSha256')) {
                $selection.OriginalCase.sourceReceiptSha256
            }
            else { $null }
            callerCommit        = $env:GITHUB_SHA
            toolsCommit         = $env:TOOLS_REF
            runId               = $env:GITHUB_RUN_ID
            runAttempt          = $env:GITHUB_RUN_ATTEMPT
        }
        $stage = 'oidc-authentication'
        if (-not $AuthenticationSucceeded) {
            throw [InvalidOperationException]::new('The existing CI OIDC login did not succeed; no fallback is permitted.')
        }
        foreach ($target in $selection.Targets) {
            $next = ''
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            for ($page = 1; $page -le (Get-AvmRetainedEvidencePolicy).MaximumPages; $page++) {
                $stage = 'endpoint-admission'
                $uri = Get-AvmRetainedEvidenceUri -Target $target -NextLink $next
                if (-not $seen.Add($uri)) {
                    throw [IO.InvalidDataException]::new('Operations pagination repeated a page.')
                }
                $stage = 'context-admission'
                $result.context = Assert-AvmRetainedEvidenceContext -Selection $selection
                $entry = @{
                    observedAtUtc = [datetime]::UtcNow.ToString('o')
                    method        = 'GET'
                    requestedId   = $target.Id
                    page          = $page
                    httpStatus    = $null
                    outcome       = 'Error'
                    observations  = @()
                }
                $result.requests.Add($entry)
                $stage = 'arm-get'
                try {
                    $response = Invoke-AzRestMethod -Method GET -Uri $uri -ErrorAction Stop
                    $entry.httpStatus = [int]$response.StatusCode
                }
                catch {
                    $nativeResponse = if ($_.Exception.PSObject.Properties['Response']) { $_.Exception.Response } else { $null }
                    if ($null -ne $nativeResponse -and $null -ne $nativeResponse.StatusCode) {
                        $entry.httpStatus = [int]$nativeResponse.StatusCode
                    }
                    if ($entry.httpStatus -ne 404) {
                        $entry.outcome = 'Blocked'
                        throw [InvalidOperationException]::new('ARM GET failed; no alternate identity or retry is permitted.')
                    }
                }
                if ($entry.httpStatus -eq 404) {
                    $entry.outcome = 'RecordAbsent'
                    break
                }
                if ($entry.httpStatus -ne 200) {
                    $entry.outcome = if ($entry.httpStatus -eq 404) { 'RecordAbsent' } else { 'Blocked' }
                    throw [InvalidOperationException]::new('ARM GET did not return an observed record.')
                }
                $stage = 'response-validation'
                $body = ConvertFrom-AvmEvidenceJson -Text $response.Content -MaximumLength 2097152
                $entry.observations = Select-AvmRetainedEvidenceResponse -Body $body -Target $target -Selection $selection
                $entry.outcome = 'Observed'
                $next = if ($target.Kind -ceq 'Operations' -and $body.Contains('nextLink')) { [string]$body.nextLink } else { '' }
                if (-not $next) {
                    break
                }
                if ($page -eq (Get-AvmRetainedEvidencePolicy).MaximumPages) {
                    $stage = 'pagination-limit'
                    $entry.outcome = 'Truncated'
                    throw [InvalidOperationException]::new('Operations page bound reached; completeness is not established.')
                }
            }
        }
        $result.status = 'Observed'
    }
    catch {
        $result.status = if ($result.requests.Count -gt 0) { 'Partial' } else { 'Blocked' }
        if ($_.Exception.Data.Contains('ObservedContext')) {
            $result.context = $_.Exception.Data['ObservedContext']
        }
        $result.failure = @{ exceptionType = $_.Exception.GetType().FullName; code = 'retained-evidence-incomplete'; stage = $stage }
    }
    finally {
        $result.requests = $result.requests.ToArray()
        Write-AvmRetainedEvidenceResult -Result $result -OutputPath $OutputPath
    }
    if ($result.status -cne 'Observed') {
        throw [InvalidOperationException]::new('Read-only evidence is incomplete; inspect the sanitized artifact.')
    }
    return $result
}
