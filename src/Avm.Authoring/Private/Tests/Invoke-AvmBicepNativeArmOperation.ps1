function Invoke-AvmBicepNativeArmOperation {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('group', 'sub', 'mg', 'tenant')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [ValidateSet('Validate', 'Create')]
        [string] $Operation,

        [Parameter(Mandatory)]
        [string] $TemplatePath,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [string] $MetadataLocation,

        [hashtable] $Parameters = @{},

        [string] $ResourceGroupName,

        [string] $ManagementGroupId,

        [ValidateNotNull()]
        [object] $DefaultProfile,

        [System.Collections.IDictionary] $SubmissionState
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $verb = if ($Operation -eq 'Create') { 'New' } else { 'Test' }
    $arguments = @{
        TemplateFile                = $TemplatePath
        TemplateParameterObject     = $Parameters
        SkipTemplateParameterPrompt = $true
        ErrorAction                 = 'Stop'
        Verbose                     = $false
        Debug                       = $false
    }
    if ($PSBoundParameters.ContainsKey('DefaultProfile')) {
        $arguments.DefaultProfile = $DefaultProfile
    }
    if ($Scope -eq 'group') {
        if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
            throw [AvmConfigurationException]::new('Native resource-group deployments require a resource group name.')
        }
        $command = "$verb-AzResourceGroupDeployment"
        $arguments.ResourceGroupName = $ResourceGroupName
        $arguments.Mode = 'Incremental'
        if ($Operation -eq 'Create') {
            $arguments.Name = $DeploymentName
            $arguments.Force = $true
        }
    }
    else {
        $arguments.Name = $DeploymentName
        $arguments.Location = $MetadataLocation
        $command = switch ($Scope) {
            'sub' { "$verb-AzSubscriptionDeployment" }
            'mg' {
                if ([string]::IsNullOrWhiteSpace($ManagementGroupId)) {
                    throw [AvmConfigurationException]::new('Native management-group deployments require a management group ID.')
                }
                $arguments.ManagementGroupId = $ManagementGroupId
                "$verb-AzManagementGroupDeployment"
            }
            'tenant' { "$verb-AzTenantDeployment" }
        }
    }
    if (-not $PSCmdlet.ShouldProcess($DeploymentName, "$Operation native ARM deployment at $Scope scope")) { return }
    Write-AvmLog -Level Info -Message (
        "Running $command for deployment '$DeploymentName' at '$Scope' scope with template '$TemplatePath' and location '$MetadataLocation'. " +
        'Template parameter values are not logged.')
    if ($Operation -eq 'Create') {
        $arguments.Confirm = $false
        $arguments.WhatIf = $false
        $deploymentCommand = Get-Command -Name $command -ErrorAction Stop
        if ($null -ne $SubmissionState) { $SubmissionState['Invoked'] = $true }
        try {
            return & $deploymentCommand @arguments
        }
        catch [System.Management.Automation.ParameterBindingException] {
            if ($null -ne $SubmissionState -and $_.InvocationInfo.MyCommand -eq $deploymentCommand) {
                $SubmissionState['Invoked'] = $false
            }
            throw
        }
    }
    $response = @(& $command @arguments)
    $errors = @($response | Where-Object {
            $null -ne (Get-AvmPropertyValue -InputObject $_ -Name 'Code') -or
            $null -ne (Get-AvmPropertyValue -InputObject $_ -Name 'Error')
        })
    if ($errors.Count -gt 0) {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [AvmProcessException]::new("ARM validation failed for deployment '$DeploymentName'; inspect its Azure validation diagnostics."),
            'AvmBicepTemplateValidationFailed', [System.Management.Automation.ErrorCategory]::InvalidResult, $errors)
        $PSCmdlet.ThrowTerminatingError($record)
    }
}
