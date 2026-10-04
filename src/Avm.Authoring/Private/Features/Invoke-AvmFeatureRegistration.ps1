function Invoke-AvmFeatureRegistration {
    <#
    .SYNOPSIS
        Ensure each feature is Registered in one subscription, then refresh its provider.

    .DESCRIPTION
        Registered features are left alone. NotRegistered or Unregistered features are
        registered and polled; Pending or unknown states stop with AVM1070. Never unregisters.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Cli,

        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [pscustomobject[]] $Feature,

        [int] $MaximumPolls = 60,

        [int] $PollIntervalSeconds = 10
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $registered = [System.Collections.Generic.List[string]]::new()
    $existing = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Feature) {
        $state = Get-AvmAzureRegistrationState -Kind Feature -Cli $Cli -Root $Root `
            -SubscriptionId $SubscriptionId -Namespace $item.Namespace -Name $item.Name
        if ($state -ceq 'Registered') {
            $existing.Add($item.FullName)
            Write-AvmLog "Azure feature $($item.FullName) is already Registered." -Level Info
            continue
        }
        if ($state -cin @('NotRegistered', 'Unregistered')) {
            $arguments = @(
                'feature', 'register', '--namespace', $item.Namespace, '--name', $item.Name,
                '--subscription', $SubscriptionId, '--output', 'none', '--only-show-errors'
            )
            $null = Invoke-AvmAzureCli -Cli $Cli -Root $Root -ArgumentList $arguments `
                -Operation "register feature $($item.FullName) in subscription $SubscriptionId" `
                -PermissionHint 'The test identity needs Microsoft.Features/* at subscription scope. '
        }
        elseif ($state -cne 'Registering') {
            if ($state -ceq 'Pending') {
                throw [AvmException]::new(
                    "Feature $($item.FullName) is Pending in subscription $SubscriptionId. Request access from the Azure service or open a support ticket before rerunning tests.",
                    'AVM1070')
            }
            throw [AvmException]::new(
                "Feature $($item.FullName) has unexpected registration state '$state' in subscription $SubscriptionId.",
                'AVM1070')
        }

        Wait-AvmAzureRegistration -Kind Feature -Cli $Cli -Root $Root `
            -SubscriptionId $SubscriptionId -Namespace $item.Namespace -Name $item.Name `
            -MaximumPolls $MaximumPolls -PollIntervalSeconds $PollIntervalSeconds

        $providerArguments = @(
            'provider', 'register', '--namespace', $item.Namespace,
            '--subscription', $SubscriptionId, '--output', 'none', '--only-show-errors'
        )
        $null = Invoke-AvmAzureCli -Cli $Cli -Root $Root -ArgumentList $providerArguments `
            -Operation "refresh provider $($item.Namespace) in subscription $SubscriptionId" `
            -PermissionHint 'The test identity needs the resource provider /register/action permission at subscription scope. '
        Wait-AvmAzureRegistration -Kind Provider -Cli $Cli -Root $Root `
            -SubscriptionId $SubscriptionId -Namespace $item.Namespace `
            -MaximumPolls $MaximumPolls -PollIntervalSeconds $PollIntervalSeconds
        $registered.Add($item.FullName)
        Write-AvmLog "Azure feature $($item.FullName) and provider $($item.Namespace) are Registered." -Level Info
    }

    return [pscustomobject]@{
        RegisteredFeatures        = $registered.ToArray()
        AlreadyRegisteredFeatures = $existing.ToArray()
    }
}
