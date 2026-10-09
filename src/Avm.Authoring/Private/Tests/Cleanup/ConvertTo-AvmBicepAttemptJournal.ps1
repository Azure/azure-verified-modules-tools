function ConvertTo-AvmBicepAttemptJournal {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $State
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($State['attempts'] -isnot [System.Collections.IList] -or $State['attempts'].Count -gt 3 -or
        -not $State.Contains('case')) {
        throw [AvmConfigurationException]::new('Invalid Bicep attempt journal.')
    }
    $number = 0
    $previous = $null
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($attempt in $State['attempts']) {
        $number++
        if ($attempt -isnot [System.Collections.IDictionary] -or
            @($attempt.psbase.Keys | Where-Object {
                    $_ -cnotin @('number', 'mode', 'namingId', 'deploymentId', 'resourceGroupName', 'resourceLocation')
                }).Count -gt 0 -or
            ($attempt['number'] -isnot [int] -and $attempt['number'] -isnot [long]) -or $attempt['number'] -ne $number -or
            $attempt['mode'] -cnotin @('Initial', 'InPlace', 'Fresh') -or
            $attempt['namingId'] -isnot [string] -or
            -not (Test-AvmBicepRunId -RunId $attempt['namingId']) -or
            $attempt['deploymentId'] -isnot [string] -or $attempt['resourceGroupName'] -isnot [string] -or
            $attempt['resourceLocation'] -isnot [string] -or $attempt['resourceLocation'] -cnotmatch '^[a-z0-9]+$') {
            throw [AvmConfigurationException]::new('Invalid Bicep attempt identity or ordering.')
        }
        $case = $State['case']
        $name = $attempt['deploymentId'].Split('/')[-1]
        $expectedId = Get-AvmBicepScopedDeploymentId -Scope $case['scope'] -SubscriptionId $State['subscriptionId'] `
            -ManagementGroupId $case['managementGroupId'] -ResourceGroupName $attempt['resourceGroupName'] -DeploymentName $name
        if ($expectedId -ine $attempt['deploymentId'] -or
            $name -cnotmatch ('^avm-e2e-' + $State['runId'] + '-t[1-3]$') -or
            @($State['deployments'] | Where-Object { $_['id'] -ieq $expectedId }).Count -ne 1) {
            throw [AvmConfigurationException]::new('Bicep attempt does not match its case and recorded deployment.')
        }
        if ($case['scope'] -eq 'group') {
            $groupId = '/subscriptions/{0}/resourceGroups/{1}' -f $State['subscriptionId'], $attempt['resourceGroupName']
            if (-not $attempt['resourceGroupName'].EndsWith('-' + $attempt['namingId'], [System.StringComparison]::Ordinal) -or
                @($State['ownedResourceGroups'] | Where-Object {
                        $_['id'] -ieq $groupId -and $_['runId'] -ceq $State['runId']
                    }).Count -ne 1) {
                throw [AvmConfigurationException]::new('Bicep attempt group is not owned by its recorded run.')
            }
        }
        elseif ($attempt['resourceGroupName'] -ne '') {
            throw [AvmConfigurationException]::new('A non-group attempt cannot select an owned resource group.')
        }
        if ($number -eq 1) {
            if ($attempt['mode'] -cne 'Initial' -or $attempt['namingId'] -cne $State['runId'] -or
                $name -cne ('avm-e2e-' + $State['runId'] + '-t1')) {
                throw [AvmConfigurationException]::new('The initial attempt must use the case naming context.')
            }
        }
        elseif ($attempt['mode'] -ceq 'InPlace') {
            foreach ($field in @('namingId', 'deploymentId', 'resourceGroupName', 'resourceLocation')) {
                if ($attempt[$field] -cne $previous[$field]) {
                    throw [AvmConfigurationException]::new('An in-place retry must preserve the previous attempt identity and location.')
                }
            }
        }
        elseif ($attempt['mode'] -cne 'Fresh' -or $name -cne ('avm-e2e-' + $State['runId'] + '-t' + $number) -or
            $names.Contains($attempt['namingId']) -or
            $ids.Contains($attempt['deploymentId'])) {
            throw [AvmConfigurationException]::new('A fresh retry must have a new external naming and deployment context.')
        }
        $null = $names.Add($attempt['namingId'])
        $null = $ids.Add($attempt['deploymentId'])
        $previous = $attempt
        [ordered]@{
            number = $number; mode = $attempt['mode']; namingId = $attempt['namingId']
            deploymentId = $attempt['deploymentId']; resourceGroupName = $attempt['resourceGroupName']
            resourceLocation = $attempt['resourceLocation']
        }
    }
    if ($ids.Count -ne $State['deployments'].Count -or
        ($null -ne $previous -and $State['case']['resourceGroupName'] -cne $previous['resourceGroupName'])) {
        throw [AvmConfigurationException]::new('Bicep attempt journal does not cover every root or the final case context.')
    }
}
