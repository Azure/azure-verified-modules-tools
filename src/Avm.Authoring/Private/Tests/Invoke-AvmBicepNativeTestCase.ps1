function Invoke-AvmBicepNativeTestCase {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Item,

        [Parameter(Mandatory)]
        [guid] $TenantId,

        [Parameter(Mandatory)]
        [string] $Location,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $AzPath,

        [Parameter(Mandatory)]
        [hashtable] $CiInput,

        [string] $ManagementGroupId,

        [string] $ResourceGroupPrefix,

        [string] $ResourceLocation,

        [string] $StatePath,

        [ValidateSet('All', 'Deploy')]
        [string] $Phase = 'All',

        [ValidateRange(1, 3)]
        [int] $DeploymentRetryLimit = 3,

        [ValidateRange(1, 3)]
        [int] $ValidationRetryLimit = 3,

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
        Location             = $Location
        RepositoryRoot       = $RepositoryRoot
        AzPath               = $AzPath
        CiInput              = $CiInput
        ManagementGroupId    = $ManagementGroupId
        ResourceGroupPrefix  = $ResourceGroupPrefix
        ResourceLocation     = $ResourceLocation
        StatePath            = $StatePath
        Phase                = $Phase
        DeploymentRetryLimit = $DeploymentRetryLimit
        ValidationRetryLimit = $ValidationRetryLimit
        KeepResources        = [bool]$KeepResources
    }
    Invoke-AvmBicepAzureContext -SubscriptionId $Item.SubscriptionId -TenantId $TenantId -ScriptBlock {
        Assert-AvmBicepAzureIdentity -AzPath $executionOptions.AzPath -SubscriptionId $Item.SubscriptionId -TenantId $TenantId
        $environment = Get-AvmPropertyValue -InputObject (Get-AzContext -ErrorAction Stop) -Name 'Environment'
        $environmentName = [string](Get-AvmPropertyValue -InputObject $environment -Name 'Name')
        $handle = New-AvmBicepCleanupState -SubscriptionId $Item.SubscriptionId -TenantId $TenantId `
            -Environment $environmentName -RunId $Item.RunId -Path $executionOptions.StatePath -Confirm:$false
        $state = $handle.State
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
            $parameters = Get-AvmBicepCiParameter -TemplateParameters $ciParameters -TemplateDefinitions $definitions `
                -Variables $executionOptions.CiInput.Variables -Secrets $executionOptions.CiInput.Secrets `
                -KeyVaultName $executionOptions.CiInput.KeyVaultName
            foreach ($key in $Item.Parameters.psbase.Keys) { $parameters[$key] = $Item.Parameters[$key] }
            if ($declared.Contains('resourceLocation') -and -not $parameters.ContainsKey('resourceLocation')) {
                $parameters['resourceLocation'] = ''
            }
            if ($declared.Contains('baseTime') -and -not $parameters.ContainsKey('baseTime')) {
                $parameters['baseTime'] = [datetime]::UtcNow.ToString('u', [cultureinfo]::InvariantCulture)
            }
            $references = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $parameters = Resolve-AvmBicepParameterToken -Value $parameters -Tokens $Item.Tokens `
                -DeferResourceLocation -ReferencedTokens $references
            $parameters = Get-AvmBicepNativeParameter -Parameters $parameters
            foreach ($key in $Item.ReferenceParameters.psbase.Keys) {
                $parameters[$key] = Resolve-AvmBicepParameterToken -Value $Item.ReferenceParameters[$key] `
                    -Tokens $Item.Tokens -DeferResourceLocation -ReferencedTokens $references
            }
            if ($null -ne $parameters['resourceLocation'] -and $parameters['resourceLocation'] -isnot [string]) {
                throw [AvmConfigurationException]::new('Regional placement requires a non-secure string resourceLocation value.')
            }
            $options = @{
                Scope          = $Item.Scope; TemplatePath = $Item.TemplatePath; MetadataLocation = $executionOptions.Location
                DeploymentName = 'avm-e2e-{0}-validation' -f $Item.RunId
                Parameters     = $parameters; ResourceGroupName = $groupName; ManagementGroupId = $executionOptions.ManagementGroupId
            }
            $selectedLocation = $executionOptions.ResourceLocation
            if ($Item.Scope -eq 'group') {
                $pinned = @(@($executionOptions.ResourceLocation, $Item.TokenResourceLocation, $parameters['resourceLocation']) |
                        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and $_ -cne '#_resourceLocation_#' } |
                        ForEach-Object { ([string]$_ -replace '\s', '').ToLowerInvariant() } | Sort-Object -Unique)
                if ($pinned.Count -gt 1) {
                    throw [AvmConfigurationException]::new('Conflicting resource locations were supplied by parameters, CI inputs or tokens.')
                }
                $selectedLocation = if ($pinned.Count -eq 1) { $pinned[0] } else {
                    (Get-AvmBicepResourceLocation -ResourceType $Item.ResourceType -MetadataLocation $executionOptions.Location).Location
                }
                $existing = Invoke-AvmBicepCleanupLookup -Command 'Get-AzResourceGroup' -Parameters @{ Name = $groupName }
                if ($null -ne $existing) {
                    throw [AvmConfigurationException]::new("Refusing to use existing resource group '$groupName'.")
                }
                $groupId = '/subscriptions/{0}/resourceGroups/{1}' -f $Item.SubscriptionId, $groupName
                $state['ownedResourceGroups'] = @(@{ id = $groupId; runId = $Item.RunId })
                Save-AvmBicepCleanupState -State $state -Path $handle.Path -Confirm:$false
                $group = New-AzResourceGroup -Name $groupName -Location $selectedLocation `
                    -Tag @{ 'avm-e2e-run-id' = $Item.RunId } -ErrorAction Stop
                if ((Get-AvmPropertyValue -InputObject $group -Name 'ResourceId') -ine $groupId -or
                    (Get-AvmPropertyValue -InputObject (
                        Get-AvmPropertyValue -InputObject $group -Name 'Tags') -Name 'avm-e2e-run-id') -cne $Item.RunId) {
                    throw [AvmProcessException]::new('The new resource group identity and ownership tag could not be verified.')
                }
            }
            $validated = Test-AvmBicepNativeDeployment -DeploymentInput $options `
                -TemplateContent $Item.TemplateContent -ResourceType $Item.ResourceType `
                -ResourceLocation $selectedLocation -TokenResourceLocation $Item.TokenResourceLocation `
                -ParameterResourceLocationToken:($references.Contains('resourceLocation')) -RetryLimit $executionOptions.ValidationRetryLimit
            $deployed = New-AvmBicepNativeDeployment -State $state -StatePath $handle.Path `
                -DeploymentInput $validated.DeploymentInput -RetryLimit $executionOptions.DeploymentRetryLimit -Confirm:$false
            if ($deployed.Status -ne 'pass') {
                Add-AvmBicepTestIssue -Issues $issues -File $Item.Case.RelativePath -Code 'deployment-failed' `
                    -Message "Deployment '$($deployed.DeploymentId)' ended with '$($deployed.Outcome)' outcome. Cleanup state is retained at '$($handle.Path)'."
            }
        }
        catch {
            if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation' -or
                $_.FullyQualifiedErrorId.Split(',')[0] -eq 'AvmBicepContextRestoreFailed') {
                $interrupted = $true
                throw
            }
            $detail = if ($_.Exception -is [AvmConfigurationException]) { $_.Exception.Message } else {
                'Native preparation, validation or submission failed. Raw parameters and Azure responses are not logged.'
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
            StatePath = $handle.Path; Issues = $issues.ToArray()
        }
    } -Confirm:$false
}
