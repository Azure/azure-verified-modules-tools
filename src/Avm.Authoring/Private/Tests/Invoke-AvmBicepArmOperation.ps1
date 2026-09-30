function Invoke-AvmBicepArmOperation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $AzPath,

        [Parameter(Mandatory)]
        [string] $TemplatePath,

        [Parameter(Mandatory)]
        [ValidateSet('group', 'sub', 'mg', 'tenant')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [ValidateSet('Validate', 'WhatIf', 'Create')]
        [string] $Operation,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [string] $ResourceGroupName,

        [string] $ManagementGroupId,

        [string] $ParameterPath,

        [string] $Location
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $command = if ($Operation -eq 'WhatIf') { 'what-if' } else { $Operation.ToLowerInvariant() }
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]]@(
            'deployment', $Scope, $command, '--template-file', $TemplatePath,
            '--name', $DeploymentName, '--subscription', $SubscriptionId,
            '--no-prompt', '--output', 'json'
        ))
    if (-not [string]::IsNullOrWhiteSpace($ParameterPath)) {
        $arguments.AddRange([string[]]@('--parameters', ('@' + $ParameterPath)))
    }
    if ($Scope -eq 'group') {
        if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
            throw [AvmConfigurationException]::new('Resource-group Bicep tests require -ResourceGroupName.')
        }
        $arguments.AddRange([string[]]@('--resource-group', $ResourceGroupName))
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Location)) {
            throw [AvmConfigurationException]::new("Bicep $Scope deployments require -Location.")
        }
        $arguments.AddRange([string[]]@('--location', $Location))
        if ($Scope -eq 'mg') {
            if ([string]::IsNullOrWhiteSpace($ManagementGroupId)) {
                throw [AvmConfigurationException]::new('Management-group Bicep tests require -ManagementGroupId.')
            }
            $arguments.AddRange([string[]]@('--management-group-id', $ManagementGroupId))
        }
    }

    return Invoke-AvmProcess -FilePath $AzPath -ArgumentList $arguments.ToArray() `
        -WorkingDirectory $WorkingDirectory -IgnoreExitCode
}
