function Read-AvmBicepWhatIfChange {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Output,

        [Parameter(Mandatory)]
        [string] $File
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Json -Json $Output -ErrorAction SilentlyContinue)) {
        throw [AvmProcessException]::new("ARM what-if for '$File' returned invalid JSON.")
    }
    $plan = $Output | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($plan -isnot [System.Collections.IDictionary] -or
        $plan['changes'] -isnot [array]) {
        throw [AvmProcessException]::new(
            "ARM what-if for '$File' returned no JSON changes array.")
    }
    foreach ($change in $plan['changes']) {
        if ($change -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$change['resourceId']) -or
            [string]::IsNullOrWhiteSpace([string]$change['changeType'])) {
            throw [AvmProcessException]::new(
                "ARM what-if for '$File' returned an invalid change.")
        }
        [pscustomobject][ordered]@{
            File       = $File
            ResourceId = [string]$change['resourceId']
            ChangeType = [string]$change['changeType']
        }
    }
}
