. (Join-Path $PSScriptRoot 'Deployment.ps1')

function Invoke-AvmWorkflowStaticValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $ResultDirectory
    )

    $path = Resolve-AvmWorkflowPath -Root $Root -RelativePath $ModulePath
    $result = Invoke-AvmTestUnit -Path $path -Ecosystem bicep -Recurse -IncludeCompliance -SkipModuleVersionCheck
    Write-AvmWorkflowResult -Name static -Result $result -Directory $ResultDirectory
}

function Invoke-AvmWorkflowPolicyValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $Example,
        [Parameter(Mandatory)] [string] $Baseline,
        [Parameter(Mandatory)] [string] $ResultDirectory
    )

    $path = Resolve-AvmWorkflowPath -Root $Root -RelativePath $ModulePath
    if (-not [string]::IsNullOrEmpty($env:TEST_SUBSCRIPTION_IDS) -or
        -not [string]::IsNullOrEmpty($env:VALIDATE_SUBSCRIPTION_ID)) {
        $pool = @(Get-AvmWorkflowSubscriptions -PoolJson $env:TEST_SUBSCRIPTION_IDS -FallbackSubscriptionId $env:VALIDATE_SUBSCRIPTION_ID)
        $env:VALIDATE_SUBSCRIPTION_ID = $pool[0].id
    }
    $result = Invoke-AvmCheckPolicy -Path $path -Ecosystem bicep -Example $Example -Baseline $Baseline -SkipModuleVersionCheck
    Write-AvmWorkflowResult -Name policy -Result $result -Directory $ResultDirectory
}

function Invoke-AvmWorkflowE2e {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [ValidateSet('Deploy', 'Complete')] [string] $Phase,
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $StatePath,
        [Parameter(Mandatory)] [string] $ResultDirectory,
        [string] $Example,
        [string] $ManagementGroupId,
        [string] $CustomLocation,
        [bool] $RemoveDeployment = $true
    )

    $path = Resolve-AvmWorkflowPath -Root $Root -RelativePath $ModulePath
    $parameters = @{
        Path = $path; Ecosystem = 'bicep'; Phase = $Phase; CleanupStatePath = $StatePath
        SubscriptionId = $SubscriptionId; TenantId = $TenantId; KeepResources = -not $RemoveDeployment
        SkipModuleVersionCheck = $true
    }
    if ($Phase -eq 'Deploy') {
        $null = Resolve-AvmWorkflowPath -Root $path -RelativePath $Example
        $parameters.Example = @($Example)
        $parameters.Recurse = $true
        $parameters.Location = 'WestEurope'
        $parameters.ResourceGroupPrefix = 'avm'
        $parameters.UseCiInputs = $true
        if (-not [string]::IsNullOrEmpty($ManagementGroupId)) { $parameters.ManagementGroupId = $ManagementGroupId }
        if (-not [string]::IsNullOrEmpty($CustomLocation)) { $parameters.ResourceLocation = $CustomLocation }
    }
    if ($PSCmdlet.ShouldProcess("$ModulePath in the selected test subscription", "Run native Bicep $Phase phase")) {
        $null = Confirm-AvmWorkflowAzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ClientId $ClientId
        $result = Invoke-AvmTestE2e @parameters -Confirm:$false
        Write-AvmWorkflowResult -Name $Phase.ToLowerInvariant() -Result $result -Directory $ResultDirectory
    }
}

function Invoke-AvmWorkflowRecovery {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $StatePath,
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $ClientId
    )

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        Write-Warning 'No persisted deployment state is available; no speculative cleanup will run.'
        return
    }
    if ($PSCmdlet.ShouldProcess($StatePath, 'Recover native Bicep cleanup without rerunning source or assertions')) {
        $null = Confirm-AvmWorkflowAzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ClientId $ClientId
        $result = Invoke-AvmTestCleanup -StatePath $StatePath -SubscriptionId $SubscriptionId `
            -TenantId $TenantId -SkipModuleVersionCheck -Confirm:$false
        if ($result.Status -ne 'pass') {
            throw [InvalidOperationException]::new('Native recovery did not complete; retain the cleanup-state artifact.')
        }
    }
}
