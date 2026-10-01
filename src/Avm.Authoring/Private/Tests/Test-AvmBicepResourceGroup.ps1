function Test-AvmBicepResourceGroup {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $AzPath,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $result = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
        'group', 'exists', '--name', $ResourceGroupName,
        '--subscription', $SubscriptionId, '--output', 'tsv'
    ) -WorkingDirectory $WorkingDirectory -IgnoreExitCode
    if ($result.ExitCode -ne 0) {
        $message = Add-AvmProcessFailureDetail `
            -Message "Could not check whether resource group '$ResourceGroupName' exists." `
            -StdErr $result.StdErr
        throw [AvmProcessException]::new($message)
    }
    $answer = ([string]$result.StdOut).Trim()
    if ($answer -cnotin @('true', 'false')) {
        throw [AvmProcessException]::new(
            "Azure CLI returned an invalid resource-group existence result for '$ResourceGroupName'.")
    }
    return $answer -ceq 'true'
}
