function Get-AvmBicepTestGroupContent {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
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
        'resource', 'list', '--resource-group', $ResourceGroupName,
        '--subscription', $SubscriptionId, '--output', 'json'
    ) -WorkingDirectory $WorkingDirectory -IgnoreExitCode
    if ($result.ExitCode -ne 0 -or
        -not (Test-Json -Json ([string]$result.StdOut) -ErrorAction SilentlyContinue)) {
        throw [AvmProcessException]::new(
            "Cannot inspect current contents of Bicep e2e group '$ResourceGroupName'.")
    }
    $contents = ConvertFrom-Json -InputObject ([string]$result.StdOut) `
        -AsHashtable -NoEnumerate -ErrorAction Stop
    if ($contents -isnot [System.Collections.IList]) {
        throw [AvmProcessException]::new(
            "Azure CLI returned uninspectable contents for Bicep e2e group '$ResourceGroupName'.")
    }
    foreach ($resource in $contents) {
        if ($resource -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$resource['id']) -or
            [string]::IsNullOrWhiteSpace([string]$resource['type']) -or
            [string]::IsNullOrWhiteSpace([string]$resource['name'])) {
            throw [AvmProcessException]::new(
                "Azure CLI returned an unidentified resource in Bicep e2e group '$ResourceGroupName'.")
        }
    }
    return $contents
}
