function Get-AvmBicepScopedDeployment {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $AzPath,

        [Parameter(Mandatory)]
        [ValidateSet('sub', 'mg', 'tenant', 'group')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [string] $ManagementGroupId,

        [string] $ResourceGroupName
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]]@(
            'deployment', $Scope, 'show', '--name', $DeploymentName,
            '--subscription', $SubscriptionId, '--output', 'json'
        ))
    if ($Scope -eq 'mg') {
        $arguments.AddRange([string[]]@('--management-group-id', $ManagementGroupId))
    }
    elseif ($Scope -eq 'group') {
        $arguments.AddRange([string[]]@('--resource-group', $ResourceGroupName))
    }
    $result = Invoke-AvmProcess -FilePath $AzPath -ArgumentList $arguments.ToArray() `
        -WorkingDirectory $WorkingDirectory -IgnoreExitCode
    if ($result.ExitCode -ne 0) {
        if (Test-AvmBicepAzNotFound -StdErr ([string]$result.StdErr)) {
            return $null
        }
        $message = Add-AvmProcessFailureDetail `
            -Message "Cannot inspect $Scope deployment '$DeploymentName'." `
            -StdErr $result.StdErr
        throw [AvmProcessException]::new($message)
    }
    if (-not (Test-Json -Json ([string]$result.StdOut) -ErrorAction SilentlyContinue)) {
        throw [AvmProcessException]::new(
            "Azure CLI returned invalid JSON for $Scope deployment '$DeploymentName'.")
    }
    $deployment = [string]$result.StdOut | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $expectedId = Get-AvmBicepScopedDeploymentId -Scope $Scope `
        -SubscriptionId $SubscriptionId -ManagementGroupId $ManagementGroupId `
        -ResourceGroupName $ResourceGroupName -DeploymentName $DeploymentName
    if ($deployment -isnot [System.Collections.IDictionary] -or
        -not [string]::Equals([string]$deployment['id'], $expectedId,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$deployment['name'], $DeploymentName,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        $deployment['properties'] -isnot [System.Collections.IDictionary] -or
        [string]::IsNullOrWhiteSpace([string]$deployment['properties']['provisioningState'])) {
        throw [AvmProcessException]::new(
            "Azure CLI returned an unrelated or incomplete $Scope deployment '$DeploymentName'.")
    }
    return [pscustomobject]@{
        Id    = $expectedId
        State = [string]$deployment['properties']['provisioningState']
    }
}
