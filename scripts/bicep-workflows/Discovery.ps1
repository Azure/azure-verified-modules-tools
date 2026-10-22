. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-AvmWorkflowInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $WorkflowPath,
        [Parameter(Mandatory)] [string] $EventName,
        [string] $EventInputs = '{}'
    )

    $path = Resolve-AvmWorkflowPath -Root $Root -RelativePath $WorkflowPath
    $parameters = @{}
    if ($EventName -eq 'workflow_dispatch') {
        $parameters = ConvertFrom-AvmWorkflowScalarInput -Json $EventInputs
    }
    else {
        Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
        $workflow = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $path -Raw)
        foreach ($entry in $workflow.on.workflow_dispatch.inputs.GetEnumerator()) {
            $parameters[$entry.Key] = $entry.Value['default']
        }
    }
    $result = [ordered]@{}
    foreach ($key in $parameters.Keys) {
        $value = $parameters[$key]
        if ($null -eq $value -or [string]$value -ceq '') { continue }
        $result[$key] = if ($value -is [bool]) { $value.ToString().ToLowerInvariant() } else { [string]$value }
    }
    return ConvertTo-Json -InputObject $result -Compress
}

function Get-AvmWorkflowTestFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [string] $PsRuleFilterRegex = '(defaults|waf-aligned)'
    )

    return Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepWorkflowTestFilesInternal -Parameters $PSBoundParameters
}

function Get-AvmWorkflowModuleMatrix {
    [CmdletBinding(DefaultParameterSetName = 'Changed')]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory, ParameterSetName = 'Requested')] [string] $ModulePaths,
        [Parameter(Mandatory, ParameterSetName = 'Changed')] [AllowEmptyCollection()] [string[]] $ChangedFiles,
        [switch] $ExcludeMetadataChanges
    )

    return Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepWorkflowModuleMatrixInternal -Parameters $PSBoundParameters
}

function Initialize-AvmWorkflowMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [ValidateSet('push', 'pull_request', 'workflow_dispatch')] [string] $EventName,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit,
        [string] $PullRequestHeadCommit,
        [string] $ModulePaths,
        [bool] $CreateReleaseTag = $false,
        [bool] $PublishOnly = $false,
        [bool] $StaticValidation = $true,
        [bool] $DeploymentValidation = $true,
        [bool] $RemoveDeployment = $true,
        [string] $CustomLocation
    )

    return Invoke-AvmWorkflowPackagePrivate -Name Initialize-AvmBicepWorkflowMatrixInternal -Parameters $PSBoundParameters
}
