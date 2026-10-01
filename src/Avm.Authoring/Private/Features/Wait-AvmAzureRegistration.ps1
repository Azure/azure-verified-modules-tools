function Wait-AvmAzureRegistration {
    [CmdletBinding()]
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

        [Parameter(Mandatory)]
        [int] $MaximumPolls,

        [Parameter(Mandatory)]
        [int] $PollIntervalSeconds
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $label = if ($Kind -eq 'Feature') { "$Namespace/$Name" } else { $Namespace }
    for ($attempt = 1; $attempt -le $MaximumPolls; $attempt++) {
        if ($attempt -gt 1) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
        $state = Get-AvmAzureRegistrationState -Kind $Kind -Cli $Cli -Root $Root `
            -SubscriptionId $SubscriptionId -Namespace $Namespace -Name $Name
        if ($state -ceq 'Registered') {
            return
        }
        if ($state -ceq 'Pending') {
            throw [AvmException]::new(
                "$Kind $label is Pending in subscription $SubscriptionId. This feature may require service approval; request access from the Azure service or open a support ticket before rerunning tests.",
                'AVM1070')
        }
        if ($state -cnotin @('Registering', 'NotRegistered', 'Unregistered')) {
            throw [AvmException]::new(
                "$Kind $label has unexpected registration state '$state' in subscription $SubscriptionId.",
                'AVM1070')
        }
    }

    throw [AvmException]::new(
        "$Kind $label did not reach Registered in subscription $SubscriptionId after $MaximumPolls checks ($PollIntervalSeconds seconds apart). Check Azure registration status and retry when it completes.",
        'AVM1070')
}
