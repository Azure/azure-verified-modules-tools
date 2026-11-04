function Start-AvmBicepNativeDeploymentJob {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Job])]
    param(
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [hashtable] $DeploymentInput
    )

    Start-ThreadJob -ArgumentList $ModulePath, $DeploymentInput -ScriptBlock {
        param($ModulePath, $DeploymentInput)
        $ErrorActionPreference = 'Stop'
        $module = Import-Module -Name $ModulePath -PassThru -ErrorAction Stop
        & $module {
            param($DeploymentInput)
            Invoke-AvmBicepNativeArmOperation @DeploymentInput -Operation Create -Confirm:$false
        } $DeploymentInput
    }
}
