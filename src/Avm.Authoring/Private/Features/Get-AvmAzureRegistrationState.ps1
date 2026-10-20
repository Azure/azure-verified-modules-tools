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

        [string] $Name,

        [scriptblock] $AssertIdentity
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
    $response = Invoke-AvmAzureCli -Cli $Cli -ArgumentList $arguments -Root $Root -AssertIdentity $AssertIdentity `
        -Operation "inspect $Kind $label in subscription $SubscriptionId"

    try {
        $data = ConvertFrom-AvmStrictJson -Json $response.StdOut -RejectCaseInsensitiveDuplicates
    }
    catch [System.ArgumentException] {
        throw [AvmException]::new(
            "Azure CLI returned invalid JSON while inspecting $Kind $label in subscription $SubscriptionId.",
            'AVM1070',
            $_.Exception)
    }
    if ($Kind -eq 'Feature') {
        $expectedId = "/subscriptions/$SubscriptionId/providers/Microsoft.Features/providers/$Namespace/features/$Name"
        $properties = $data['properties']
        $state = $null
        if ($properties -is [System.Collections.IDictionary]) { $state = $properties['state'] }
        if ($data['id'] -isnot [string] -or $data['id'] -ine $expectedId -or
            $data['name'] -isnot [string] -or $data['name'] -ine $label -or
            $state -isnot [string] -or [string]::IsNullOrWhiteSpace($state)) {
            throw [AvmException]::new(
                "Azure CLI returned an unexpected feature identity or state for $label in subscription $SubscriptionId.",
                'AVM1070')
        }
    }
    else {
        $state = $data['registrationState']
        $expectedId = "/subscriptions/$SubscriptionId/providers/$Namespace"
        if ($data['namespace'] -isnot [string] -or $data['namespace'] -ine $Namespace -or
            ($data.Contains('id') -and ($data['id'] -isnot [string] -or $data['id'] -ine $expectedId)) -or
            $state -isnot [string] -or [string]::IsNullOrWhiteSpace($state)) {
            throw [AvmException]::new(
                "Azure CLI returned an unexpected provider identity or state for $Namespace in subscription $SubscriptionId.",
                'AVM1070')
        }
    }

    return $state
}
