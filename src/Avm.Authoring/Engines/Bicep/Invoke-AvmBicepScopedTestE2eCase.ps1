function Invoke-AvmBicepScopedTestE2eCase {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Item,

        [Parameter(Mandatory)]
        [string] $AzPath,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $Location,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [string] $ManagementGroupId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $changes = [System.Collections.Generic.List[object]]::new()
    $assertions = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.List[string]]::new()
    $casePassed = $false
    $caseFailed = $false
    $attempted = $false
    $createAttempted = $false
    $plan = $null
    $stage = 'preflight'
    $scope = $Item.Scope
    $deploymentName = $Item.DeploymentName
    $casePath = $Item.Case.RelativePath
    $target = Get-AvmBicepScopedDeploymentId -Scope $scope `
        -SubscriptionId $SubscriptionId -ManagementGroupId $ManagementGroupId `
        -DeploymentName $deploymentName
    if (-not $PSCmdlet.ShouldProcess($target, 'Deploy Bicep test and remove verified owned resources')) {
        return [pscustomobject]@{
            Attempted = 0; Passed = $false; Failed = $false
            CleanupPending = @(); AssertionResults = @(); WhatIfChanges = @(); Issues = @()
        }
    }
    $attempted = $true
    $scopeGroupId = if ($scope -eq 'mg') { $ManagementGroupId } else { $null }
    $armInput = @{
        AzPath            = $AzPath
        TemplatePath      = $Item.TemplatePath
        Scope             = $scope
        SubscriptionId    = $SubscriptionId
        ManagementGroupId = $scopeGroupId
        DeploymentName    = $deploymentName
        WorkingDirectory  = $WorkingDirectory
        Location          = $Location
        ParameterPath     = $Item.ParameterPath
    }
    $deploymentInput = @{
        AzPath            = $AzPath
        Scope             = $scope
        SubscriptionId    = $SubscriptionId
        ManagementGroupId = $scopeGroupId
        DeploymentName    = $deploymentName
        WorkingDirectory  = $WorkingDirectory
    }
    try {
        Assert-AvmBicepScopedAccount -AzPath $AzPath -SubscriptionId $SubscriptionId `
            -TenantId $TenantId -ManagementGroupId $scopeGroupId `
            -WorkingDirectory $WorkingDirectory
        if ($null -ne (Get-AvmBicepScopedDeployment @deploymentInput)) {
            throw [AvmConfigurationException]::new(
                "Deployment '$target' already exists; refusing to overwrite its history.")
        }
        $stage = 'validate'
        $validated = Invoke-AvmBicepArmOperation @armInput -Operation Validate
        if ($validated.ExitCode -ne 0) {
            $message = Add-AvmProcessFailureDetail `
                -Message "ARM validate failed for '$target' (exit $($validated.ExitCode))." `
                -StdErr $validated.StdErr
            throw [AvmProcessException]::new($message)
        }
        $stage = 'what-if'
        $preview = Invoke-AvmBicepArmOperation @armInput -Operation WhatIf
        if ($preview.ExitCode -ne 0) {
            $message = Add-AvmProcessFailureDetail `
                -Message "ARM what-if failed for '$target' (exit $($preview.ExitCode))." `
                -StdErr $preview.StdErr
            throw [AvmProcessException]::new($message)
        }
        $plan = Read-AvmBicepScopedWhatIf -Output ([string]$preview.StdOut) `
            -File $casePath -Scope $scope -SubscriptionId $SubscriptionId `
            -ManagementGroupId $scopeGroupId -RunId $Item.RunId
        foreach ($change in $plan.Changes) {
            $changes.Add($change)
        }
        $stage = 'ownership'
        foreach ($resource in $plan.Resources) {
            $state = Get-AvmBicepScopedResourceState -AzPath $AzPath `
                -Resource $resource -SubscriptionId $SubscriptionId -RunId $Item.RunId `
                -WorkingDirectory $WorkingDirectory
            if ($state.Exists) {
                throw [AvmConfigurationException]::new(
                    "Resource '$($resource.Id)' already exists; refusing to modify it.")
            }
        }
        foreach ($nested in $plan.Deployments) {
            if ($null -ne (Get-AvmBicepScopedDeployment -AzPath $AzPath `
                        -Scope $scope -SubscriptionId $SubscriptionId `
                        -ManagementGroupId $scopeGroupId -DeploymentName $nested.Name `
                        -WorkingDirectory $WorkingDirectory)) {
                throw [AvmConfigurationException]::new(
                    "Nested deployment '$($nested.Id)' already exists; refusing to overwrite its history.")
            }
        }
        Assert-AvmBicepScopedAccount -AzPath $AzPath -SubscriptionId $SubscriptionId `
            -TenantId $TenantId -ManagementGroupId $scopeGroupId `
            -WorkingDirectory $WorkingDirectory
        $stage = 'deployment'
        $createAttempted = $true
        $deployed = Invoke-AvmBicepArmOperation @armInput -Operation Create
        if ($deployed.ExitCode -ne 0) {
            $message = Add-AvmProcessFailureDetail `
                -Message "ARM deployment failed for '$target' (exit $($deployed.ExitCode))." `
                -StdErr $deployed.StdErr
            throw [AvmProcessException]::new($message)
        }
        $stage = 'deployment-verification'
        Assert-AvmBicepDeploymentSucceeded -Output ([string]$deployed.StdOut) `
            -Scope $scope -SubscriptionId $SubscriptionId `
            -ManagementGroupId $scopeGroupId -DeploymentName $deploymentName
        $stage = 'assertions'
        $assertionResult = Invoke-AvmBicepTestE2eAssertion -Item $Item `
            -DeploymentName $deploymentName -DeploymentOutput ([string]$deployed.StdOut) `
            -RepositoryRoot $RepositoryRoot -Issues $issues
        $assertions.Add($assertionResult)
        if ($assertionResult.Status -eq 'fail') {
            $caseFailed = $true
        }
        else {
            $casePassed = $true
        }
    }
    catch [AvmProcessException] {
        $code = switch ($stage) {
            'validate' { 'validate-failed' }
            'what-if' { 'what-if-failed' }
            'deployment' { 'deployment-failed' }
            'deployment-verification' { 'deployment-unverified' }
            default { 'process-failed' }
        }
        Add-AvmBicepTestIssue -Issues $issues -File $casePath -Code $code `
            -Message "$scope Bicep e2e $stage failed for '$target': $($_.Exception.Message)"
        $caseFailed = $true
    }
    catch [AvmConfigurationException] {
        $code = if ($stage -eq 'what-if') { 'what-if-unsafe' } else { 'preflight-unsafe' }
        Add-AvmBicepTestIssue -Issues $issues -File $casePath -Code $code `
            -Message "$scope Bicep e2e $stage refused for '$target': $($_.Exception.Message)"
        $caseFailed = $true
    }
    catch [System.TimeoutException] {
        Add-AvmBicepTestIssue -Issues $issues -File $casePath -Code 'process-timeout' `
            -Message "$scope Bicep e2e $stage timed out for '$target': $($_.Exception.Message)"
        $caseFailed = $true
    }
    finally {
        if ($createAttempted) {
            try {
                $cleanup = Remove-AvmBicepScopedDeploymentResource -AzPath $AzPath `
                    -Scope $scope -SubscriptionId $SubscriptionId -TenantId $TenantId `
                    -ManagementGroupId $scopeGroupId -DeploymentName $deploymentName `
                    -RunId $Item.RunId -Plan $plan -WorkingDirectory $WorkingDirectory `
                    -Confirm:$false
            }
            catch [AvmProcessException] {
                $cleanup = [pscustomobject]@{
                    Cleaned = $false
                    Pending = @($plan.Resources | ForEach-Object { $_.Id })
                    Message = $_.Exception.Message
                }
            }
            catch [System.TimeoutException] {
                $cleanup = [pscustomobject]@{
                    Cleaned = $false
                    Pending = @($plan.Resources | ForEach-Object { $_.Id })
                    Message = $_.Exception.Message
                }
            }
            if (-not $cleanup.Cleaned) {
                foreach ($id in $cleanup.Pending) {
                    $pending.Add($id)
                }
                $message = "$($cleanup.Message) Deployment '$target' requires manual cleanup verification."
                Add-AvmBicepTestIssue -Issues $issues -File $casePath `
                    -Code 'cleanup-failed' -Message $message
                Write-AvmLog $message -Level Error
                $casePassed = $false
                $caseFailed = $true
            }
        }
    }
    return [pscustomobject]@{
        Attempted        = [int]$attempted
        Passed           = $casePassed
        Failed           = $caseFailed
        CleanupPending   = $pending.ToArray()
        AssertionResults = $assertions.ToArray()
        WhatIfChanges    = $changes.ToArray()
        Issues           = $issues.ToArray()
    }
}
