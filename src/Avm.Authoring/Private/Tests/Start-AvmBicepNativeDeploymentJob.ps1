function Start-AvmBicepNativeDeploymentJob {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Management.Automation.Job])]
    param(
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [hashtable] $DeploymentInput,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $AzureModulePaths,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $SubmissionState
    )

    if (-not $PSCmdlet.ShouldProcess($DeploymentInput.DeploymentName, 'Start Azure deployment')) { return }
    $workerModulePath = $ModulePath
    $workerAzureModulePaths = $AzureModulePaths
    $workerSubmissionState = $SubmissionState
    Start-ThreadJob -ScriptBlock {
        $ModulePath = $using:workerModulePath
        $DeploymentInput = $using:DeploymentInput
        $AzureModulePaths = $using:workerAzureModulePaths
        $SubmissionState = $using:workerSubmissionState
        $ErrorActionPreference = 'Stop'
        foreach ($azureModulePath in $AzureModulePaths) {
            Import-Module -Name $azureModulePath -ErrorAction Stop
        }
        $module = Import-Module -Name $ModulePath -PassThru -ErrorAction Stop
        & $module {
            param($DeploymentInput, $SubmissionState)
            Invoke-AvmBicepNativeArmOperation @DeploymentInput -Operation Create -SubmissionState $SubmissionState -Confirm:$false
        } $DeploymentInput $SubmissionState
    }
}
