function Write-AvmBicepWhatIf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $DeploymentInput,
        [AllowEmptyCollection()] [string[]] $SensitiveValues = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $scope = $DeploymentInput.Scope
    $arguments = @{
        Name                        = $DeploymentInput.DeploymentName
        TemplateFile                = $DeploymentInput.TemplatePath
        TemplateParameterObject     = $DeploymentInput.Parameters
        SkipTemplateParameterPrompt = $true
        ResultFormat                = 'ResourceIdOnly'
        ErrorAction                 = 'Stop'
    }
    if ($DeploymentInput.ContainsKey('DefaultProfile')) { $arguments.DefaultProfile = $DeploymentInput.DefaultProfile }
    if ($scope -eq 'group') {
        $command = 'Get-AzResourceGroupDeploymentWhatIfResult'
        $arguments.ResourceGroupName = $DeploymentInput.ResourceGroupName
        $arguments.Mode = 'Incremental'
    }
    else {
        $arguments.Location = $DeploymentInput.MetadataLocation
        $command = switch ($scope) {
            'sub' { 'Get-AzSubscriptionDeploymentWhatIfResult' }
            'mg' {
                $arguments.ManagementGroupId = $DeploymentInput.ManagementGroupId
                'Get-AzManagementGroupDeploymentWhatIfResult'
            }
            'tenant' { 'Get-AzTenantDeploymentWhatIfResult' }
            default { throw [AvmConfigurationException]::new("Unsupported What-If scope '$scope'.") }
        }
    }
    Write-AvmLog -Level Info -Message (
        "Running $command for deployment '$($DeploymentInput.DeploymentName)' at '$scope' scope, " +
        "location '$($DeploymentInput.MetadataLocation)', template '$($DeploymentInput.TemplatePath)' (ResourceIdOnly).")
    try {
        $result = & $command @arguments
        $changes = @(Get-AvmPropertyValue -InputObject $result -Name 'Changes' | Where-Object { $null -ne $_ })
        Write-AvmLog -Level Info -Message "Found $($changes.Count) resource changes in What-If."
        $counts = @{ Create = 0; Modify = 0; Deploy = 0; Delete = 0 }
        foreach ($change in $changes) {
            $id = [string](Get-AvmPropertyValue -InputObject $change -Name 'FullyQualifiedResourceId' -NoEnumerate)
            $kind = [string](Get-AvmPropertyValue -InputObject $change -Name 'ChangeType' -NoEnumerate)
            if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($kind)) {
                throw [AvmProcessException]::new('What-If returned a change without a resource ID or change type.')
            }
            if ($counts.ContainsKey($kind)) { $counts[$kind]++ }
            Write-AvmLog -Level Info -Message "  $kind $id"
        }
        Write-AvmLog -Level Info -Message (
            "Plan: $($counts.Create) to create, $($counts.Modify + $counts.Deploy) to change, $($counts.Delete) to delete.")
    }
    catch {
        if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') { throw }
        $detail = Protect-AvmBicepDiagnosticText -Text $_.Exception.Message -SensitiveValues $SensitiveValues
        Write-AvmLog -Level Warning -Message "What-If could not be completed; validation and deployment continue. $detail"
    }
}
