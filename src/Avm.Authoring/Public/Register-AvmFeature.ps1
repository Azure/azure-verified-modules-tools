function Register-AvmFeature {
    <#
    .SYNOPSIS
        Ensure features declared at a module root are registered in one Azure test subscription.

    .DESCRIPTION
        Reads the optional .required-features.json string array at the exact
        module root, or for a Bicep registry module the repository-root object
        entry keyed by its exact avm/... module path, and validates every entry
        before accessing Azure. Requires
        an explicit subscription GUID and an Azure CLI session selected to
        that same subscription. Already Registered features are left alone.
        Missing features are registered, polled until Registered, and their
        resource provider is registered again to propagate the change.
        Pending approval, failed CLI calls, and timeouts stop the test run.
        Feature registrations persist; this command never unregisters them.

    .PARAMETER Path
        Module root. Bicep registry modules read the repository-root manifest.

    .PARAMETER SubscriptionId
        GUID of the selected test subscription. Must also match any effective
        ARM_SUBSCRIPTION_ID and the Azure CLI's selected subscription.

    .PARAMETER MaximumPolls
        Maximum status checks per feature or provider. Defaults to 60.

    .PARAMETER PollIntervalSeconds
        Seconds between status checks. Defaults to 10.

    .OUTPUTS
        pscustomobject with Status, SubscriptionId, FeaturesTotal,
        RegisteredFeatures, AlreadyRegisteredFeatures, and Reason.

    .EXAMPLE
        avm register-features --subscription-id 00000000-0000-4000-8000-000000000001

    .EXAMPLE
        Register-AvmFeature -SubscriptionId $testSubscriptionId -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [ValidateRange(1, 120)]
        [int] $MaximumPolls = 60,

        [ValidateRange(1, 60)]
        [int] $PollIntervalSeconds = 10,

        [switch] $SkipModuleVersionCheck
    )

    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
    }
    process {
        Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

        $context = Get-AvmModuleContextInternal -Path $Path
        $features = @(Get-AvmContextRequiredFeature -Context $context)
        $subscription = [guid]::Empty
        if (-not [guid]::TryParseExact($SubscriptionId, 'D', [ref]$subscription) -or
            $subscription -eq [guid]::Empty) {
            throw [AvmConfigurationException]::new(
                'Supply an explicit, nonempty subscription GUID with -SubscriptionId.')
        }
        $subscriptionId = $subscription.ToString('D')
        $result = [pscustomobject]@{
            Status                    = 'skipped'
            SubscriptionId            = $subscriptionId
            FeaturesTotal             = $features.Count
            RegisteredFeatures        = @()
            AlreadyRegisteredFeatures = @()
            Reason                    = 'No required Azure features declared.'
        }
        if ($features.Count -eq 0) {
            return $result
        }

        if (-not [string]::IsNullOrWhiteSpace($env:ARM_SUBSCRIPTION_ID)) {
            $effective = [guid]::Empty
            if (-not [guid]::TryParseExact($env:ARM_SUBSCRIPTION_ID, 'D', [ref]$effective) -or
                $effective -ne $subscription) {
                throw [AvmConfigurationException]::new(
                    'The effective ARM_SUBSCRIPTION_ID does not match the selected test subscription; refusing to register Azure features.')
            }
        }

        if (-not $PSCmdlet.ShouldProcess("Azure subscription $subscriptionId", "Ensure $($features.Count) required feature(s) are registered")) {
            $result.Reason = 'Registration was not approved (WhatIf or Confirm).'
            return $result
        }

        $cli = Resolve-AvmAzureCli
        $account = Invoke-AvmAzureCli -Cli $cli -Root $context.Root `
            -ArgumentList @('account', 'show', '--query', 'id', '--output', 'tsv', '--only-show-errors') `
            -Operation 'check the selected Azure subscription'
        $selected = ([string]$account.StdOut).Trim()
        if (-not [string]::Equals($selected, $subscriptionId, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw [AvmException]::new(
                "Azure CLI is not selected to subscription $subscriptionId. Log in to that test subscription with the same identity used for the tests before registering features.",
                'AVM1070')
        }

        $outcome = Invoke-AvmFeatureRegistration -Cli $cli -Root $context.Root -SubscriptionId $subscriptionId `
            -Feature $features -MaximumPolls $MaximumPolls -PollIntervalSeconds $PollIntervalSeconds
        $result.Status = 'pass'
        $result.RegisteredFeatures = $outcome.RegisteredFeatures
        $result.AlreadyRegisteredFeatures = $outcome.AlreadyRegisteredFeatures
        $result.Reason = ''
        return $result
    }
}
