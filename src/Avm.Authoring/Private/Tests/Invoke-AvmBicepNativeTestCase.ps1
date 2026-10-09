function Invoke-AvmBicepNativeTestCase {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Item,
        [Parameter(Mandatory)] [guid] $TenantId,
        [Parameter(Mandatory)] [string] $Location,
        [Parameter(Mandatory)] [string] $RepositoryRoot,
        [Parameter(Mandatory)] [string] $AzPath,
        [Parameter(Mandatory)] [hashtable] $CiInput,
        [string] $ManagementGroupId,
        [string] $ResourceGroupPrefix,
        [string] $ResourceLocation,
        [string] $StatePath,
        [ValidateSet('All', 'Deploy')] [string] $Phase = 'All',
        [ValidateRange(1, 3)] [int] $DeploymentRetryLimit = 3,
        [ValidateRange(1, 3)] [int] $ValidationRetryLimit = 3,
        [switch] $KeepResources
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess($Item.Case.RelativeDirectory, 'Run native Bicep deployment test')) {
        return [pscustomobject]@{
            Status = 'skipped'; AssertionResults = @(); PostResults = @(); Issues = @()
            CleanupPending = @(); CleanupDeferred = $false; StatePath = ''
        }
    }
    $executionOptions = @{
        Location = $Location; RepositoryRoot = $RepositoryRoot; AzPath = $AzPath; CiInput = $CiInput
        ManagementGroupId = $ManagementGroupId; ResourceGroupPrefix = $ResourceGroupPrefix
        ResourceLocation = $ResourceLocation; StatePath = $StatePath; Phase = $Phase
        DeploymentRetryLimit = $DeploymentRetryLimit; ValidationRetryLimit = $ValidationRetryLimit
        KeepResources = [bool]$KeepResources
    }
    Invoke-AvmBicepAzureContext -SubscriptionId $Item.SubscriptionId -TenantId $TenantId -ScriptBlock {
        Assert-AvmBicepAzureIdentity -AzPath $executionOptions.AzPath -SubscriptionId $Item.SubscriptionId -TenantId $TenantId
        $features = @(Get-AvmPropertyValue -InputObject $Item -Name 'RequiredFeatures')
        if ($features.Count -gt 0) {
            try {
                $null = Invoke-AvmFeatureRegistration -Cli (Resolve-AvmAzureCli) -Root $executionOptions.RepositoryRoot `
                    -SubscriptionId ([guid]$Item.SubscriptionId).ToString('D') -Feature $features
            }
            catch [AvmException] {
                $registrationIssues = [System.Collections.Generic.List[object]]::new()
                Add-AvmBicepTestIssue -Issues $registrationIssues -File $Item.Case.RelativePath `
                    -Code 'feature-registration-failed' -Message $_.Exception.Message
                return [pscustomobject]@{
                    Status = 'fail'; AssertionResults = @(); PostResults = @(); Issues = $registrationIssues.ToArray()
                    CleanupPending = @(); CleanupDeferred = $false; StatePath = ''
                }
            }
        }
        $environment = Get-AvmPropertyValue -InputObject (Get-AzContext -ErrorAction Stop) -Name 'Environment'
        $environmentName = [string](Get-AvmPropertyValue -InputObject $environment -Name 'Name')
        $handle = New-AvmBicepCleanupState -SubscriptionId $Item.SubscriptionId -TenantId $TenantId `
            -Environment $environmentName -RunId $Item.RunId -Path $executionOptions.StatePath -Confirm:$false
        $state = $handle.State
        $state['attempts'] = @()
        $groupName = if ($Item.Scope -eq 'group') { '{0}-{1}' -f $executionOptions.ResourceGroupPrefix, $Item.RunId } else { '' }
        $state['case'] = [ordered]@{
            path = $Item.Case.RelativePath; scope = $Item.Scope; resourceGroupName = $groupName
            managementGroupId = if ($Item.Scope -eq 'mg') { $executionOptions.ManagementGroupId } else { '' }
            metadataLocation = $executionOptions.Location; sourceHash = $Item.SourceHash; completionStarted = $false
        }
        Save-AvmBicepCleanupState -State $state -Path $handle.Path -Confirm:$false
        Write-AvmLog -Level Info -Message "Bicep cleanup state for '$($Item.Case.RelativeDirectory)': $($handle.Path)"
        $issues = [System.Collections.Generic.List[object]]::new()
        $completion = $null
        $interrupted = $false
        $deployed = $null
        try {
            $definitions = $Item.Template['definitions']
            if ($null -eq $definitions) { $definitions = @{} }
            $declared = $Item.Template['parameters']
            if ($null -eq $declared) { $declared = @{} }
            $ciParameters = [ordered]@{}
            foreach ($name in $declared.psbase.Keys) {
                if (-not $Item.Parameters.ContainsKey($name) -and -not $Item.ReferenceParameters.ContainsKey($name)) {
                    $ciParameters[$name] = $declared[$name]
                }
            }
            $baseParameters = Get-AvmBicepCiParameter -TemplateParameters $ciParameters -TemplateDefinitions $definitions `
                -Variables $executionOptions.CiInput.Variables -Secrets $executionOptions.CiInput.Secrets `
                -KeyVaultName $executionOptions.CiInput.KeyVaultName
            $baseTime = [datetime]::UtcNow.ToString('u', [cultureinfo]::InvariantCulture)
            $unavailableRegions = @()
            $mode = 'Initial'
            $namingIndex = -1
            $retryBlocked = $false
            $freshChangesRegion = $Item.RetryPolicy['modes']['Fresh']['location'] -ceq 'NextEligible'
            $attemptLimit = [Math]::Min($executionOptions.DeploymentRetryLimit, $Item.RetryPolicy['limits']['deploymentAttempts'])
            for ($attempt = 1; $attempt -le $attemptLimit; $attempt++) {
                if ($mode -ne 'InPlace') {
                    $namingIndex++
                    $attemptInput = $Item.AttemptInputs[$namingIndex]
                    $parameters = $baseParameters.Clone()
                    foreach ($key in $attemptInput.Parameters.psbase.Keys) { $parameters[$key] = $attemptInput.Parameters[$key] }
                    if ($declared.Contains('resourceLocation') -and -not $parameters.ContainsKey('resourceLocation')) {
                        $parameters['resourceLocation'] = ''
                    }
                    if ($declared.Contains('baseTime') -and -not $parameters.ContainsKey('baseTime')) { $parameters['baseTime'] = $baseTime }
                    $references = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $parameters = Resolve-AvmBicepParameterToken -Value $parameters -Tokens $attemptInput.Tokens `
                        -DeferResourceLocation -ReferencedTokens $references
                    $parameters = Get-AvmBicepNativeParameter -Parameters $parameters
                    foreach ($key in $attemptInput.ReferenceParameters.psbase.Keys) {
                        $parameters[$key] = Resolve-AvmBicepParameterToken -Value $attemptInput.ReferenceParameters[$key] `
                            -Tokens $attemptInput.Tokens -DeferResourceLocation -ReferencedTokens $references
                    }
                    if ($null -ne $parameters['resourceLocation'] -and $parameters['resourceLocation'] -isnot [string]) {
                        throw [AvmConfigurationException]::new('Regional placement requires a non-secure string resourceLocation value.')
                    }
                    $selectedLocation = $executionOptions.ResourceLocation
                    if ($mode -eq 'Fresh' -and -not $freshChangesRegion) { $selectedLocation = $validated.Location }
                    $groupCanRelocate = $false
                    if ($Item.Scope -eq 'group') {
                        $groupName = '{0}-{1}' -f $executionOptions.ResourceGroupPrefix, $attemptInput.NamingId
                        $pinned = @(@($executionOptions.ResourceLocation, $Item.TokenResourceLocation, $parameters['resourceLocation']) |
                                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and $_ -cne '#_resourceLocation_#' } |
                                ForEach-Object { ([string]$_ -replace '\s', '').ToLowerInvariant() } | Sort-Object -Unique)
                        if ($pinned.Count -gt 1) {
                            throw [AvmConfigurationException]::new('Conflicting resource locations were supplied by parameters, CI inputs or tokens.')
                        }
                        if ($mode -eq 'Fresh' -and -not $freshChangesRegion) { $selectedLocation = $validated.Location }
                        elseif ($pinned.Count -eq 1) { $selectedLocation = $pinned[0] }
                        else {
                            $selection = Get-AvmBicepResourceLocation -ResourceType $Item.ResourceType `
                                -MetadataLocation $executionOptions.Location -UnavailableRegions $unavailableRegions
                            $selectedLocation = $selection.Location
                            $groupCanRelocate = -not $selection.IsGlobal
                        }
                        New-AvmBicepAttemptGroup -State $state -StatePath $handle.Path -Name $groupName `
                            -Location $selectedLocation -Confirm:$false
                    }
                    $options = @{
                        Scope = $Item.Scope; TemplatePath = $Item.TemplatePath; MetadataLocation = $executionOptions.Location
                        DeploymentName = 'avm-e2e-{0}-t{1}' -f $Item.RunId, $attempt
                        Parameters = $parameters; ResourceGroupName = $groupName; ManagementGroupId = $executionOptions.ManagementGroupId
                    }
                    $validated = Test-AvmBicepNativeDeployment -DeploymentInput $options -SubscriptionId $Item.SubscriptionId `
                        -TemplateContent $attemptInput.TemplateContent -ResourceType $Item.ResourceType `
                        -ResourceLocation $selectedLocation -TokenResourceLocation $Item.TokenResourceLocation `
                        -ParameterResourceLocationToken:($references.Contains('resourceLocation')) `
                        -UnavailableRegions $unavailableRegions -RetryLimit $executionOptions.ValidationRetryLimit
                    $canFresh = -not $freshChangesRegion -or
                    (($validated.CanRelocate -or $groupCanRelocate) -and
                    $validated.AttemptedRegions.Count -lt $executionOptions.ValidationRetryLimit)
                }
                $deployed = New-AvmBicepNativeDeployment -State $state -StatePath $handle.Path `
                    -DeploymentInput $validated.DeploymentInput -Attempt $attempt -Mode $mode -NamingId $attemptInput.NamingId `
                    -ClassifyRetry:($attempt -lt $attemptLimit) -ResourceLocation $validated.Location -Confirm:$false
                if ($deployed.Status -eq 'pass' -or $attempt -eq $attemptLimit -or -not $deployed.RetryMode -or
                    ($deployed.RetryMode -eq 'Fresh' -and -not $canFresh)) { break }

                # ARM can overwrite nested operation history even when the next root name changes.
                $snapshot = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($deployed.DeploymentId) `
                    -RequireCompleteRemoval -SearchRetryLimit 1 -SearchRetryInterval 0
                $state['resources'] = @(Get-AvmBicepCleanupResourceRecord -Existing $state['resources'] -ResourceIds $snapshot.ResourceIds)
                Save-AvmBicepCleanupState -State $state -Path $handle.Path -Confirm:$false
                if ($snapshot.Issues.Count -gt 0) {
                    foreach ($issue in $snapshot.Issues) { Write-AvmLog -Level Warning -Message $issue.Message }
                    Add-AvmBicepTestIssue -Issues $issues -File $Item.Case.RelativePath -Code 'retry-evidence-incomplete' `
                        -Message "The failed attempt's resource history could not be preserved completely; retry stopped. Cleanup state: '$($handle.Path)'."
                    $retryBlocked = $true
                    break
                }
                $mode = $deployed.RetryMode
                if ($mode -eq 'Fresh' -and $freshChangesRegion) { $unavailableRegions = $validated.AttemptedRegions }
                Write-AvmLog -Level Warning -Message "Retrying '$($deployed.DeploymentName)' in $mode mode ($attempt/$attemptLimit); all resources remain until finalization."
                Start-Sleep -Seconds $Item.RetryPolicy['limits']['delaySeconds']
            }
            if ($deployed.Status -ne 'pass' -and -not $retryBlocked) {
                $authorizationDetail = if ($deployed.ErrorKind -eq 'Forbidden') {
                    ' Submission returned HTTP 403; authorization failures never permit replay.'
                }
                else { '' }
                Add-AvmBicepTestIssue -Issues $issues -File $Item.Case.RelativePath -Code 'deployment-failed' `
                    -Message "Deployment '$($deployed.DeploymentId)' ended with '$($deployed.Outcome)' outcome.$authorizationDetail Cleanup state is retained at '$($handle.Path)'."
            }
        }
        catch {
            if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation' -or
                $_.FullyQualifiedErrorId.Split(',')[0] -eq 'AvmBicepContextRestoreFailed') {
                $interrupted = $true
                throw
            }
            $detail = if ($_.Exception -is [AvmConfigurationException]) { $_.Exception.Message } else {
                $codes = @(Get-AvmBicepSafeErrorCode -ErrorRecord $_)
                $codeText = if ($codes.Count -gt 0) { " Azure error codes: $($codes -join ', ')." } else { '' }
                "Native preparation, validation or submission failed.$codeText Raw parameters and Azure responses are not logged."
            }
            Add-AvmBicepTestIssue -Issues $issues -File $Item.Case.RelativePath -Code 'native-execution-failed' `
                -Message "$detail Cleanup state: '$($handle.Path)'."
        }
        finally {
            if ($executionOptions.Phase -eq 'All' -and -not $interrupted) {
                $completion = Complete-AvmBicepTestCase -Item $Item -StatePath $handle.Path `
                    -SubscriptionId $Item.SubscriptionId -TenantId $TenantId -RepositoryRoot $executionOptions.RepositoryRoot `
                    -AzPath $executionOptions.AzPath -KeepResources:$executionOptions.KeepResources -Confirm:$false
            }
        }
        if ($null -ne $completion) {
            foreach ($issue in $completion.Issues) { $issues.Add($issue) }
        }
        $passed = $null -ne $deployed -and $deployed.Status -eq 'pass' -and $issues.Count -eq 0 -and
        ($executionOptions.Phase -eq 'Deploy' -or ($null -ne $completion -and $completion.Status -eq 'pass'))
        [pscustomobject]@{
            Status           = if ($passed) { 'pass' } else { 'fail' }
            AssertionResults = @(if ($null -ne $completion) { $completion.AssertionResults })
            PostResults      = @(if ($null -ne $completion) { $completion.PostResults })
            CleanupPending   = @(if ($null -ne $completion) { $completion.CleanupPending })
            CleanupDeferred  = $executionOptions.Phase -eq 'Deploy' -or $executionOptions.KeepResources -or
            ($null -ne $completion -and $completion.CleanupDeferred)
            StatePath        = $handle.Path
            Issues           = $issues.ToArray()
        }
    } -Confirm:$false
}
