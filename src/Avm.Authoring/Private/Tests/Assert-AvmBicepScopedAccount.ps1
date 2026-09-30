function Assert-AvmBicepScopedAccount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $AzPath,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [string] $ManagementGroupId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $account = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
        'account', 'show', '--subscription', $SubscriptionId, '--output', 'json'
    ) -WorkingDirectory $WorkingDirectory -IgnoreExitCode
    if ($account.ExitCode -ne 0) {
        $message = Add-AvmProcessFailureDetail `
            -Message "Cannot verify Bicep e2e subscription '$SubscriptionId'." `
            -StdErr $account.StdErr
        throw [AvmProcessException]::new($message)
    }
    if (-not (Test-Json -Json ([string]$account.StdOut) -ErrorAction SilentlyContinue)) {
        throw [AvmProcessException]::new('Azure CLI returned an invalid Bicep e2e account response.')
    }
    $selected = [string]$account.StdOut | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($selected -isnot [System.Collections.IDictionary] -or
        -not [string]::Equals([string]$selected['id'], $SubscriptionId,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$selected['tenantId'], $TenantId,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        $selected['state'] -cne 'Enabled') {
        throw [AvmConfigurationException]::new(
            "Selected Azure CLI account does not confirm the enabled subscription '$SubscriptionId' in tenant '$TenantId'.")
    }

    if (-not [string]::IsNullOrWhiteSpace($ManagementGroupId)) {
        $group = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
            'account', 'management-group', 'show', '--name', $ManagementGroupId,
            '--subscription', $SubscriptionId, '--output', 'json'
        ) -WorkingDirectory $WorkingDirectory -IgnoreExitCode
        if ($group.ExitCode -ne 0) {
            $message = Add-AvmProcessFailureDetail `
                -Message "Cannot verify Bicep e2e management group '$ManagementGroupId'." `
                -StdErr $group.StdErr
            throw [AvmProcessException]::new($message)
        }
        if (-not (Test-Json -Json ([string]$group.StdOut) -ErrorAction SilentlyContinue)) {
            throw [AvmProcessException]::new('Azure CLI returned an invalid Bicep e2e management-group response.')
        }
        $shown = [string]$group.StdOut | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $expectedId = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
        if ($shown -isnot [System.Collections.IDictionary] -or
            -not [string]::Equals([string]$shown['id'], $expectedId,
                [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$shown['name'], $ManagementGroupId,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw [AvmConfigurationException]::new(
                "Azure CLI did not confirm the explicit Bicep e2e management group '$ManagementGroupId'.")
        }
    }
}
