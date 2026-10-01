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
        throw [System.ArgumentException]::new('Only the five Bicep execution variables may be written.')
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

function Invoke-AvmBicepTestTenantSync {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Plan')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values,
        [Parameter(ParameterSetName = 'Plan')] [switch] $PlanOnly = $true,
        [Parameter(Mandatory, ParameterSetName = 'Apply')] [switch] $Apply
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($PSCmdlet.ParameterSetName -ceq 'Plan' -and -not $PlanOnly) {
        throw [System.ArgumentException]::new('Use -Apply explicitly to publish; -PlanOnly:$false is not an apply flag.')
    }
    $bundle = Get-AvmBamiSettings -Values $Values
    $projection = Get-AvmBamiSettings -Values $bundle -BicepOnly
    $snapshot = Get-AvmBicepTestTenantSnapshot
    $retargetedNames = @(
        foreach ($name in $projection.Keys) {
            if ($null -ne $snapshot[$name] -and $snapshot[$name].Value -cne $projection[$name]) { $name }
        }
    )
    if ($retargetedNames.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "Existing BAMI execution values cannot change: $($retargetedNames -join ', '). Retargeting requires coordinated maintenance; routine publication cannot overwrite present values."
        )
    }
    $changes = @(
        foreach ($name in $projection.Keys) {
            if ($null -eq $snapshot[$name]) { $name }
        }
    )
    $publishing = $PSCmdlet.ParameterSetName -ceq 'Apply' -and $Apply.IsPresent
    $result = [ordered]@{
        Target = 'Azure/bicep-registry-modules'
        Status = if ($changes.Count -eq 0) { 'NoChange' } else { 'Planned' }
        PlanOnly = -not $publishing
        HasChanges = $changes.Count -gt 0
        ChangedNames = $changes
    }
    if (-not $publishing) { return [pscustomobject]$result }
    if ($changes.Count -gt 0 -and -not $PSCmdlet.ShouldProcess($result.Target, 'Initialize missing nonsecret Bicep execution variables')) {
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
        $final = Get-AvmBicepTestTenantSnapshot
        Assert-AvmBicepTestTenantSnapshot -Expected $snapshot -Actual $final -Stage 'final publication readback'
    }
    catch {
        throw [System.InvalidOperationException]::new(
            "Bicep variable synchronization stopped. Partial execution values or outside edits may remain; publication is unverified. No automatic rollback or write retry was performed. $($_.Exception.Message)",
            $_.Exception
        )
    }
    if ($changes.Count -gt 0) {
        $result.Status = 'Published'
    }
    return [pscustomobject]$result
}
