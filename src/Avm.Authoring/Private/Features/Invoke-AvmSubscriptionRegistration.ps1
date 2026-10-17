function Invoke-AvmSubscriptionRegistration {
    <#
    .SYNOPSIS
        Ensure each requested feature or provider is Registered in one subscription.

    .DESCRIPTION
        Registered entries are left alone. NotRegistered or Unregistered entries are
        registered and polled; Registering entries are polled without resubmission.
        Newly completed features also refresh their provider. Never unregisters.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Cli,

        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]] $Requirement,

        [ValidateSet('Feature', 'Provider')]
        [string] $Kind = 'Feature',

        [ValidateRange(1, 120)]
        [int] $MaximumPolls = 60,

        [ValidateRange(0, 60)]
        [int] $PollIntervalSeconds = 10,

        [scriptblock] $AssertIdentity
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $registered = [System.Collections.Generic.List[string]]::new()
    $existing = [System.Collections.Generic.List[string]]::new()
    if ($Requirement.Count -eq 0 -or -not $PSCmdlet.ShouldProcess(
            $SubscriptionId, "Register $($Requirement.Count) required Azure $Kind entries")) {
        Write-AvmLog -Level Info -Message "Required Azure $Kind registration is skipped."
        return [pscustomobject]@{ Registered = @(); AlreadyRegistered = @() }
    }
    foreach ($item in $Requirement) {
        $state = Get-AvmAzureRegistrationState -Kind $Kind -Cli $Cli -Root $Root -AssertIdentity $AssertIdentity `
            -SubscriptionId $SubscriptionId -Namespace $item.Namespace -Name $item.Name
        if ($state -ceq 'Registered') {
            $existing.Add($item.FullName)
            Write-AvmLog "Azure $Kind $($item.FullName) is already Registered." -Level Info
            continue
        }
        if ($state -cin @('NotRegistered', 'Unregistered')) {
            $arguments = @($Kind.ToLowerInvariant(), 'register', '--namespace', $item.Namespace)
            if ($Kind -eq 'Feature') { $arguments += @('--name', $item.Name) }
            $arguments += @('--subscription', $SubscriptionId, '--output', 'none', '--only-show-errors')
            $permission = if ($Kind -eq 'Feature') { 'Microsoft.Features/*' } else { 'the resource provider /register/action permission' }
            $null = Invoke-AvmAzureCli -Cli $Cli -Root $Root -ArgumentList $arguments -AssertIdentity $AssertIdentity `
                -Operation "register $Kind $($item.FullName) in subscription $SubscriptionId" `
                -PermissionHint "The test identity needs $permission at subscription scope. "
        }
        elseif ($state -cne 'Registering') {
            if ($state -ceq 'Pending') {
                throw [AvmException]::new(
                    "$Kind $($item.FullName) is Pending in subscription $SubscriptionId. Request access from the Azure service or open a support ticket before rerunning tests.",
                    'AVM1070')
            }
            throw [AvmException]::new(
                "$Kind $($item.FullName) has unexpected registration state '$state' in subscription $SubscriptionId.",
                'AVM1070')
        }

        Wait-AvmAzureRegistration -Kind $Kind -Cli $Cli -Root $Root -AssertIdentity $AssertIdentity `
            -SubscriptionId $SubscriptionId -Namespace $item.Namespace -Name $item.Name `
            -MaximumPolls $MaximumPolls -PollIntervalSeconds $PollIntervalSeconds

        if ($Kind -eq 'Feature') {
            $providerArguments = @(
                'provider', 'register', '--namespace', $item.Namespace,
                '--subscription', $SubscriptionId, '--output', 'none', '--only-show-errors'
            )
            $null = Invoke-AvmAzureCli -Cli $Cli -Root $Root -ArgumentList $providerArguments -AssertIdentity $AssertIdentity `
                -Operation "refresh provider $($item.Namespace) in subscription $SubscriptionId" `
                -PermissionHint 'The test identity needs the resource provider /register/action permission at subscription scope. '
            Wait-AvmAzureRegistration -Kind Provider -Cli $Cli -Root $Root -AssertIdentity $AssertIdentity `
                -SubscriptionId $SubscriptionId -Namespace $item.Namespace `
                -MaximumPolls $MaximumPolls -PollIntervalSeconds $PollIntervalSeconds
        }
        $registered.Add($item.FullName)
        Write-AvmLog "Azure $Kind $($item.FullName) registration is complete." -Level Info
    }

    return [pscustomobject]@{
        Registered        = $registered.ToArray()
        AlreadyRegistered = $existing.ToArray()
    }
}
