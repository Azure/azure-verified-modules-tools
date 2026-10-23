. (Join-Path $PSScriptRoot 'ModuleConfig.ps1')

function Get-AvmBicepTestTenantSnapshotDifference {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Actual
    )

    foreach ($name in Get-AvmBicepTestTenantVariableNames) {
        if ($null -eq $Expected[$name] -or $null -eq $Actual[$name]) {
            if ($null -ne $Expected[$name] -or $null -ne $Actual[$name]) { $name }
            continue
        }
        foreach ($field in @('Name', 'Value', 'CreatedAt', 'UpdatedAt')) {
            if ($Expected[$name].$field -cne $Actual[$name].$field) {
                $name
                break
            }
        }
    }
}

function Assert-AvmBicepTestTenantSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Actual,
        [Parameter(Mandatory)] [string] $Stage
    )

    $differences = @(Get-AvmBicepTestTenantSnapshotDifference -Expected $Expected -Actual $Actual)
    if ($differences.Count -gt 0) {
        throw [System.InvalidOperationException]::new("Consumer variables changed outside this sync during ${Stage}: $($differences -join ', ').")
    }
}

function Set-AvmBicepTestTenantVariable {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Name -cnotin @(Get-AvmBicepTestTenantVariableNames)) {
        throw [System.ArgumentException]::new('Only the five Bicep execution variables and the module client-ID mapping may be written.')
    }
    if (-not $PSCmdlet.ShouldProcess("Azure/bicep-registry-modules/$Name", 'Publish a nonsecret Actions variable')) {
        throw [System.OperationCanceledException]::new('The nonsecret variable write was not approved.')
    }
    # GitHub variables have no CAS. These checks detect observed drift, not an atomic transaction.
    $before = Get-AvmBicepTestTenantSnapshot
    Assert-AvmBicepTestTenantSnapshot -Expected $Expected -Actual $before -Stage "pre-write $Name"
    $method = if ($null -eq $before[$Name]) { 'POST' } else { 'PATCH' }
    $writeError = $null
    try {
        $null = Invoke-AvmBicepTestTenantVariableApi -Method $method -Name $Name -Value $Value -Confirm:$false
    }
    catch {
        $writeError = $_.Exception
    }
    for ($readbackAttempt = 0; $readbackAttempt -le 3; $readbackAttempt++) {
        try {
            $after = Get-AvmBicepTestTenantSnapshot
        }
        catch {
            $acknowledgement = if ($writeError) { 'was not acknowledged' } else { 'was acknowledged' }
            $failure = [System.InvalidOperationException]::new(
                "The write of $Name $acknowledgement, and consumer readback failed. Its outcome is unverified; inspect consumer execution values before retrying.",
                $_.Exception
            )
            if ($writeError) { $failure.Data['WriteError'] = $writeError }
            throw $failure
        }

        $anticipated = [ordered]@{}
        foreach ($key in $Expected.Keys) { $anticipated[$key] = $Expected[$key] }
        $anticipated[$Name] = [pscustomobject]@{
            Name = $Name
            Value = $Value
            CreatedAt = if ($null -ne $before[$Name]) { $before[$Name].CreatedAt } elseif ($null -ne $after[$Name]) { $after[$Name].CreatedAt } else { '' }
            UpdatedAt = if ($null -ne $after[$Name]) { $after[$Name].UpdatedAt } else { '' }
        }
        $differences = @(Get-AvmBicepTestTenantSnapshotDifference -Expected $anticipated -Actual $after)
        if ($writeError) {
            $observation = if ($differences.Count -gt 0) {
                "Readback does not match the expected publication: $($differences -join ', ')."
            }
            else {
                'Readback confirms the requested execution value is present and other execution values are unchanged.'
            }
            throw [System.InvalidOperationException]::new("The write of $Name was not acknowledged. $observation No write retry or rollback was attempted.", $writeError)
        }
        if ($differences.Count -eq 0) { return $after }
        $unchanged = @(Get-AvmBicepTestTenantSnapshotDifference -Expected $before -Actual $after).Count -eq 0
        if ($unchanged -and $readbackAttempt -lt 3) {
            $retryDelay = 5 * ($readbackAttempt + 1)
            Write-Information "Waiting $retryDelay seconds for readback visibility of $Name; retrying only the GET, not the acknowledged write." -InformationAction Continue
            Start-Sleep -Seconds $retryDelay
            continue
        }
        throw [System.InvalidOperationException]::new(
            "Readback mismatch after writing ${Name}: $($differences -join ', ') after $($readbackAttempt + 1) readback attempt(s). The consumer may contain partial writes or outside edits."
        )
    }
}

function Resolve-AvmBicepSubscriptionPoolPublication {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ExistingJson,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings
    )

    $existingSettings = [ordered]@{}
    foreach ($name in $Settings.Keys) { $existingSettings[$name] = $Settings[$name] }
    $existingSettings['TEST_BAMI_SUBSCRIPTION_IDS'] = $ExistingJson
    $existing = ConvertFrom-AvmTestTenantJson -Json (Get-AvmBamiSettings -Values $existingSettings).TEST_BAMI_SUBSCRIPTION_IDS
    $requested = ConvertFrom-AvmTestTenantJson -Json $Settings['TEST_BAMI_SUBSCRIPTION_IDS']
    $changed = $false
    for ($index = 0; $index -lt $existing.Count; $index++) {
        $before = $existing[$index]
        $after = $requested[$index]
        if ($before['id'] -cne $after['id'] -or $before['name'] -cne $after['name']) {
            throw [System.InvalidOperationException]::new(
                'Existing BAMI execution values cannot change: VALIDATE_SUBSCRIPTION_IDS. Only tags on the same ordered subscription identities and names may change; retargeting requires coordinated maintenance.'
            )
        }
        $previousTag = if ($before.Contains('tag')) { $before['tag'] } else { 'General' }
        if ($previousTag -cne 'General' -and -not $after.Contains('tag')) {
            throw [System.InvalidOperationException]::new(
                'An untagged source cannot erase an existing subscription reservation. Resolve this maintenance conflict with an explicit tag before publication.'
            )
        }
        $requestedTag = if ($after.Contains('tag')) { $after['tag'] } else { 'General' }
        if ($previousTag -cne $requestedTag) { $changed = $true }
    }
    if (-not $changed) { return $ExistingJson }
    return $Settings['TEST_BAMI_SUBSCRIPTION_IDS']
}

function Invoke-AvmBicepTestTenantSync {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Plan')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values,
        [System.Collections.IDictionary] $ModuleClientIds,
        [System.Collections.IDictionary] $IdentityMigration,
        [System.Collections.IDictionary] $BillingScopes,
        [Parameter(ParameterSetName = 'Plan')] [switch] $PlanOnly = $true,
        [Parameter(Mandatory, ParameterSetName = 'Apply')] [switch] $Apply
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($PSCmdlet.ParameterSetName -ceq 'Plan' -and -not $PlanOnly) {
        throw [System.ArgumentException]::new('Use -Apply explicitly to publish; -PlanOnly:$false is not an apply flag.')
    }
    $bundle = Get-AvmBamiSettings -Values $Values
    $execution = Get-AvmBamiSettings -Values $bundle -BicepOnly
    $projection = [ordered]@{
        VALIDATE_TENANT_ID = $execution.TEST_BAMI_TENANT_ID
        VALIDATE_CLIENT_ID = $execution.TEST_BAMI_BICEP_CLIENT_ID
        VALIDATE_PERSISTENT_SUBSCRIPTION_ID = $execution.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
        VALIDATE_MANAGEMENT_GROUP_ID = $execution.TEST_BAMI_MANAGEMENT_GROUP_ID
        VALIDATE_SUBSCRIPTION_IDS = $execution.TEST_BAMI_SUBSCRIPTION_IDS
    }
    $moduleJson = $null
    $forbidden = @($bundle.TEST_BAMI_CONTROLLER_CLIENT_ID, $bundle.TEST_BAMI_BICEP_CLIENT_ID)
    if ($PSBoundParameters.ContainsKey('ModuleClientIds')) {
        $moduleJson = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $ModuleClientIds -ForbiddenClientIds $forbidden
    }
    if ($PSBoundParameters.ContainsKey('IdentityMigration')) {
        if (-not $PSBoundParameters.ContainsKey('ModuleClientIds') -or $null -eq $IdentityMigration) {
            throw [System.ArgumentException]::new('Identity rename evidence requires its complete proposed module client-ID mapping.')
        }
        $null = ConvertFrom-AvmBicepIdentityMigration -Migration $IdentityMigration -ClientIds $ModuleClientIds -Settings $bundle
    }
    $billingScopeSecret = $null
    if ($PSBoundParameters.ContainsKey('BillingScopes')) {
        $billingScopeSecret = ConvertTo-AvmBicepModuleBillingScopeJson -BillingScopes $BillingScopes
    }
    $snapshot = Get-AvmBicepTestTenantSnapshot
    $retargetedNames = @(
        foreach ($name in $projection.Keys) {
            if ($null -ne $snapshot[$name] -and $snapshot[$name].Value -cne $projection[$name]) { $name }
        }
    )
    if (@($retargetedNames | Where-Object { $_ -cne 'VALIDATE_SUBSCRIPTION_IDS' }).Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "Existing BAMI execution values cannot change: $($retargetedNames -join ', '). Retargeting requires coordinated maintenance; routine publication cannot overwrite present values."
        )
    }
    if ($retargetedNames -ccontains 'VALIDATE_SUBSCRIPTION_IDS') {
        if (@($projection.Keys | Where-Object {
                    $_ -cne 'VALIDATE_MODULE_CLIENT_IDS' -and $null -eq $snapshot[$_]
                }).Count -gt 0 -or [string]::IsNullOrEmpty($snapshot['VALIDATE_SUBSCRIPTION_IDS'].Value)) {
            throw [System.InvalidOperationException]::new('Existing BAMI execution values cannot change: VALIDATE_SUBSCRIPTION_IDS. Tag updates require the complete matching Bicep execution bundle; missing or empty values require coordinated maintenance.')
        }
        $projection['VALIDATE_SUBSCRIPTION_IDS'] = Resolve-AvmBicepSubscriptionPoolPublication `
            -ExistingJson $snapshot['VALIDATE_SUBSCRIPTION_IDS'].Value -Settings $bundle
    }
    if ($PSBoundParameters.ContainsKey('ModuleClientIds')) {
        $projection['VALIDATE_MODULE_CLIENT_IDS'] = $moduleJson
        if ($null -ne $snapshot['VALIDATE_MODULE_CLIENT_IDS']) {
            Assert-AvmBicepModuleMappingExtension -ExistingJson $snapshot['VALIDATE_MODULE_CLIENT_IDS'].Value `
                -ClientIds $ModuleClientIds -ForbiddenClientIds $forbidden -IdentityMigration $IdentityMigration -Settings $bundle
        }
    }
    $changes = @(
        foreach ($name in $projection.Keys) {
            if ($null -eq $snapshot[$name] -or
                ($name -cin @('VALIDATE_MODULE_CLIENT_IDS', 'VALIDATE_SUBSCRIPTION_IDS') -and
                    $snapshot[$name].Value -cne $projection[$name])) { $name }
        }
    )
    $publishing = $PSCmdlet.ParameterSetName -ceq 'Apply' -and $Apply.IsPresent
    $secretAction = if ($null -ne $billingScopeSecret) { 'Set' } else { 'None' }
    $result = [ordered]@{
        Target = 'Azure/bicep-registry-modules'
        Status = if ($changes.Count -eq 0) { 'NoChange' } else { 'Planned' }
        PlanOnly = -not $publishing
        HasChanges = $changes.Count -gt 0 -or $secretAction -cne 'None'
        ChangedNames = $changes
        BillingScopeSecretAction = $secretAction
    }
    if ($secretAction -cne 'None' -and $result.Status -ceq 'NoChange') {
        $result.Status = 'Planned'
    }
    if (-not $publishing) { return [pscustomobject]$result }
    if (($changes.Count -gt 0 -or $secretAction -cne 'None') -and
        -not $PSCmdlet.ShouldProcess($result.Target, 'Publish nonsecret Bicep variables and the guarded billing-scope environment secret')) {
        $result.Status = 'Preview'
        $result.PlanOnly = $true
        return [pscustomobject]$result
    }

    try {
        foreach ($name in $changes) {
            $snapshot = Set-AvmBicepTestTenantVariable -Expected $snapshot -Name $name -Value $projection[$name] -Confirm:$false
        }
        $readback = Get-AvmBicepTestTenantSnapshot
        Assert-AvmBicepTestTenantSnapshot -Expected $snapshot -Actual $readback -Stage 'complete execution-value readback'
        foreach ($name in $projection.Keys) {
            $observed = if ($null -ne $readback[$name]) { $readback[$name].Value } else { $null }
            if ($observed -cne $projection[$name]) {
                throw [System.InvalidOperationException]::new("Complete execution-value readback does not match $name.")
            }
        }
        if ($secretAction -ceq 'Set') {
            Set-AvmBicepRegistryBillingScopeSecret -Value $billingScopeSecret -Confirm:$false
        }
        $final = Get-AvmBicepTestTenantSnapshot
        Assert-AvmBicepTestTenantSnapshot -Expected $snapshot -Actual $final -Stage 'final publication readback'
    }
    catch {
        throw [System.InvalidOperationException]::new(
            "Bicep variable synchronization stopped. Partial execution values or outside edits may remain; publication is unverified. No automatic rollback or write retry was performed. $($_.Exception.Message)",
            $_.Exception
        )
    }
    if ($changes.Count -gt 0 -or $secretAction -cne 'None') {
        $result.Status = 'Published'
    }
    return [pscustomobject]$result
}
