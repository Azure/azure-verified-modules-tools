function Get-AvmAzureRegistrationState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Feature', 'Provider')]
        [string] $Kind,

        [Parameter(Mandatory)]
        [pscustomobject] $Cli,

        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Namespace,

        [string] $Name
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $arguments = if ($Kind -eq 'Feature') {
        [string[]]@(
            'feature', 'show', '--namespace', $Namespace, '--name', $Name,
            '--subscription', $SubscriptionId, '--output', 'json', '--only-show-errors'
        )
    }
    else {
        [string[]]@(
            'provider', 'show', '--namespace', $Namespace,
            '--subscription', $SubscriptionId, '--output', 'json', '--only-show-errors'
        )
    }
    $label = if ($Kind -eq 'Feature') { "$Namespace/$Name" } else { $Namespace }
    $response = Invoke-AvmAzureCli -Cli $Cli -ArgumentList $arguments -Root $Root `
        -Operation "inspect $Kind $label in subscription $SubscriptionId"

    try {
        $data = ConvertFrom-Json -InputObject $response.StdOut -ErrorAction Stop
    }
    catch {
        throw [AvmException]::new(
            "Azure CLI returned invalid JSON while inspecting $Kind $label in subscription $SubscriptionId.",
            'AVM1070',
            $_.Exception)
    }
    if ($null -eq $data -or $data -isnot [pscustomobject]) {
        throw [AvmException]::new(
            "Azure CLI returned an unexpected JSON value while inspecting $Kind $label in subscription $SubscriptionId.",
            'AVM1070')
    }

    if ($Kind -eq 'Feature') {
        $expectedId = "/subscriptions/$SubscriptionId/providers/Microsoft.Features/providers/$Namespace/features/$Name"
        $properties = $data.PSObject.Properties['properties']
        $state = if ($null -ne $properties -and $null -ne $properties.Value) {
            $properties.Value.PSObject.Properties['state']
        }
        else {
            $null
        }
        if ($null -eq $data.PSObject.Properties['id'] -or
            -not [string]::Equals([string]$data.id, $expectedId, [System.StringComparison]::OrdinalIgnoreCase) -or
            $null -eq $data.PSObject.Properties['name'] -or
            -not [string]::Equals([string]$data.name, $label, [System.StringComparison]::OrdinalIgnoreCase) -or
            $null -eq $state -or
            [string]::IsNullOrWhiteSpace([string]$state.Value)) {
            throw [AvmException]::new(
                "Azure CLI returned an unexpected feature identity or state for $label in subscription $SubscriptionId.",
                'AVM1070')
        }
    }
    else {
        $state = $data.PSObject.Properties['registrationState']
        if ($null -eq $data.PSObject.Properties['namespace'] -or
            -not [string]::Equals([string]$data.namespace, $Namespace, [System.StringComparison]::OrdinalIgnoreCase) -or
            $null -eq $state -or
            [string]::IsNullOrWhiteSpace([string]$state.Value)) {
            throw [AvmException]::new(
                "Azure CLI returned an unexpected provider identity or state for $Namespace in subscription $SubscriptionId.",
                'AVM1070')
        }
    }

    return [string]$state.Value
}
