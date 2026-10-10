function Complete-AvmBicepTestCase {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Item,

        [Parameter(Mandatory)]
        [string] $StatePath,

        [Parameter(Mandatory)]
        [guid] $SubscriptionId,

        [Parameter(Mandatory)]
        [guid] $TenantId,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $AzPath,

        [switch] $KeepResources
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $state = Read-AvmBicepCleanupState -Path $StatePath
    if ($state['subscriptionId'] -ine $SubscriptionId.ToString('D') -or
        $state['tenantId'] -ine $TenantId.ToString('D') -or -not $state.Contains('case') -or
        $state['case']['path'] -cne $Item.Case.RelativePath -or $state['case']['scope'] -cne $Item.Scope) {
        throw [AvmConfigurationException]::new('Completion state does not match the selected case, subscription and tenant.')
    }
    if ($state['status'] -eq 'Complete' -or $state['case']['completionStarted']) {
        throw [AvmConfigurationException]::new(
            'This case was already completed or completion was interrupted. Use avm test cleanup to resume deletion without rerunning authored scripts.')
    }
    if ($state['case']['sourceHash'] -cne (Get-AvmBicepTestSourceHash -Case $Item.Case)) {
        throw [AvmConfigurationException]::new(
            'The case source, assertions or post hook changed after deployment. Restore the original checkout, or use avm test cleanup without running changed scripts.')
    }
    if (-not $PSCmdlet.ShouldProcess($Item.Case.RelativeDirectory, 'Complete Bicep assertions and ordinary cleanup')) {
        return [pscustomobject]@{
            Status = 'skipped'; AssertionResults = @(); PostResults = @()
            CleanupPending = @(); CleanupDeferred = $true; StatePath = $StatePath; Issues = @()
        }
    }
    $completionOptions = @{
        RepositoryRoot = $RepositoryRoot
        AzPath         = $AzPath
        KeepResources  = [bool]$KeepResources
    }
    Invoke-AvmBicepAzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ScriptBlock {
        $environment = Get-AvmPropertyValue -InputObject (Get-AzContext -ErrorAction Stop) -Name 'Environment'
        if ((Get-AvmPropertyValue -InputObject $environment -Name 'Name') -cne $state['environment']) {
            throw [AvmConfigurationException]::new('Completion state belongs to a different Azure cloud.')
        }
        Assert-AvmBicepAzureIdentity -AzPath $completionOptions.AzPath -SubscriptionId $SubscriptionId -TenantId $TenantId
        $issues = [System.Collections.Generic.List[object]]::new()
        $assertions = [System.Collections.Generic.List[object]]::new()
        $posts = [System.Collections.Generic.List[object]]::new()
        $readiness = Get-AvmBicepPendingDeployment -State $state
        Save-AvmBicepCleanupState -State $state -Path $StatePath -Confirm:$false
        if ($readiness.Pending.Count -gt 0) {
            foreach ($issue in $readiness.Issues) {
                Add-AvmBicepTestIssue -Issues $issues -File $Item.Case.RelativePath `
                    -Code 'deployment-pending' -Message $issue.Message
            }
            return [pscustomobject]@{
                Status = 'fail'; AssertionResults = @(); PostResults = @()
                CleanupPending = $readiness.Pending; CleanupDeferred = $true
                StatePath = $StatePath; Issues = $issues.ToArray()
            }
        }
        $case = $state['case']
        $case['completionStarted'] = $true
        Save-AvmBicepCleanupState -State $state -Path $StatePath -Confirm:$false
        $deployment = if ($state['deployments'].Count -gt 0) { $state['deployments'][-1] } else { $null }
        $succeeded = $null -ne $deployment -and $deployment['status'] -ceq 'Succeeded'
        $cleanup = $null
        $interrupted = $false
        try {
            if ($succeeded) {
                $assertion = Invoke-AvmBicepAzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ScriptBlock {
                    $response = Invoke-AvmBicepRead -Activity 'Read assertion deployment outputs' -Read {
                        Invoke-AzRestMethod -Method GET -Path ($deployment['id'] + '?api-version=2021-04-01') -ErrorAction Stop
                    }
                    $document = ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Read assertion deployment outputs'
                    if ($document.Contains('error') -or $document['id'] -isnot [string] -or $document['id'] -ine $deployment['id'] -or
                        $document['properties'] -isnot [System.Collections.IDictionary] -or
                        $document['properties']['provisioningState'] -isnot [string] -or
                        $document['properties']['provisioningState'] -cne 'Succeeded') {
                        throw [AvmProcessException]::new('The exact successful deployment could not be confirmed for assertions.')
                    }
                    Invoke-AvmBicepTestE2eAssertion -Item $Item -DeploymentName $deployment['id'].Split('/')[-1] `
                        -DeploymentOutput $response.Content -RepositoryRoot $completionOptions.RepositoryRoot -Issues $issues -InProcess
                } -Confirm:$false
                $assertions.Add($assertion)
            }
            elseif ($null -ne $deployment) {
                Add-AvmBicepTestIssue -Issues $issues -File $Item.Case.RelativePath -Code 'deployment-failed' `
                    -Message "Deployment '$($deployment['id'])' did not succeed; assertions were not run."
            }
        }
        catch {
            if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation' -or
                $_.FullyQualifiedErrorId.Split(',')[0] -eq 'AvmBicepContextRestoreFailed') {
                $interrupted = $true
                throw
            }
            Add-AvmBicepTestIssue -Issues $issues -File $Item.Case.RelativePath -Code 'completion-failed' `
                -Message 'The deployment result or authored assertions could not be completed; ordinary cleanup will still run.'
        }
        finally {
            if (-not $completionOptions.KeepResources -and -not $interrupted) {
                try {
                    if ($null -ne $deployment) {
                        $post = Invoke-AvmBicepAzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ScriptBlock {
                            Assert-AvmBicepAzureIdentity -AzPath $completionOptions.AzPath -SubscriptionId $SubscriptionId -TenantId $TenantId
                            Invoke-AvmBicepE2ePostHook -Item $Item -ModuleRoot $Item.Case.ModuleRoot `
                                -SubscriptionId $SubscriptionId.ToString('D') -TenantId $TenantId.ToString('D') `
                                -ManagementGroupId $case['managementGroupId'] -ResourceGroupName $case['resourceGroupName'] `
                                -Location $case['metadataLocation'] -DeploymentName $deployment['id'].Split('/')[-1] `
                                -RunId $state['runId'] -Issues $issues -InProcess
                        } -Confirm:$false
                        $posts.Add($post)
                    }
                }
                catch {
                    if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation' -or
                        $_.FullyQualifiedErrorId.Split(',')[0] -eq 'AvmBicepContextRestoreFailed') {
                        $interrupted = $true
                        throw
                    }
                    Add-AvmBicepTestIssue -Issues $issues -File $Item.Case.RelativePath -Code 'post-hook-failed' `
                        -Message 'The post hook could not finish in the selected Azure context; ordinary cleanup will still run.'
                }
                finally {
                    if (-not $interrupted) {
                        try {
                            $cleanup = Invoke-AvmBicepCleanup -StatePath $StatePath `
                                -SubscriptionId $SubscriptionId -TenantId $TenantId -Confirm:$false
                        }
                        catch {
                            if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation' -or
                                $_.FullyQualifiedErrorId.Split(',')[0] -eq 'AvmBicepContextRestoreFailed') { throw }
                            $cleanup = [pscustomobject]@{
                                Cleaned = $false
                                Pending = @(@($state['deployments']) + @($state['ownedResourceGroups']) | ForEach-Object { $_['id'] })
                                Issues  = @([pscustomobject]@{
                                        Message = "Cleanup could not finish. Resume the saved state at '$StatePath' with avm test cleanup."
                                    })
                            }
                        }
                        foreach ($issue in $cleanup.Issues) {
                            Add-AvmBicepTestIssue -Issues $issues -File $Item.Case.RelativePath `
                                -Code 'cleanup-failed' -Message $issue.Message
                        }
                    }
                }
            }
        }
        $passed = $succeeded -and $issues.Count -eq 0 -and
        @($assertions | Where-Object Status -EQ 'fail').Count -eq 0 -and
        @($posts | Where-Object Status -EQ 'fail').Count -eq 0 -and
        ($completionOptions.KeepResources -or ($null -ne $cleanup -and $cleanup.Cleaned))
        [pscustomobject]@{
            Status         = if ($passed) { 'pass' } else { 'fail' }
            AssertionResults = $assertions.ToArray(); PostResults = $posts.ToArray()
            CleanupPending = @(if ($null -ne $cleanup) { $cleanup.Pending })
            CleanupDeferred  = $completionOptions.KeepResources; StatePath = $StatePath; Issues = $issues.ToArray()
        }
    } -Confirm:$false
}
