function Get-AvmBicepResourceLock {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [string] $Type = ''
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $inputParameters = @{ Scope = $ResourceId; ErrorAction = 'Stop' }
    if ($Type -ieq 'Microsoft.Authorization/locks') {
        $match = [regex]::Match($ResourceId,
            '^(?<scope>.+)/providers/Microsoft\.Authorization/locks/(?<name>[^/]+)$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            throw [AvmConfigurationException]::new("Invalid resource lock ID: $ResourceId")
        }
        $inputParameters.Scope = $match.Groups['scope'].Value
        $inputParameters.LockName = $match.Groups['name'].Value
    }
    try {
        $locks = @(Get-AzResourceLock @inputParameters)
    }
    catch {
        if ((Get-AvmBicepAzureErrorStatus -ErrorRecord $_) -eq 404) {
            return @()
        }
        throw
    }

    foreach ($lock in $locks) {
        $lockId = if ($lock -is [System.Collections.IDictionary]) {
            [string]$lock['LockId']
        }
        elseif ($null -ne $lock.PSObject.Properties['LockId']) {
            [string]$lock.LockId
        }
        else { '' }
        if ([string]::IsNullOrWhiteSpace($lockId)) {
            throw [AvmProcessException]::new("Azure returned a lock without its ID for '$ResourceId'.")
        }
        $isTarget = [string]::Equals(
            $lockId, $ResourceId, [System.StringComparison]::OrdinalIgnoreCase)
        $isDescendant = $lockId.StartsWith(
            $ResourceId.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase)
        if (($Type -ieq 'Microsoft.Authorization/locks' -and $isTarget) -or
            ($Type -ine 'Microsoft.Authorization/locks' -and $isDescendant)) {
            $lock
        }
        else {
            Write-AvmLog "Leaving lock '$lockId' outside cleanup target '$ResourceId'." -Level Warning
        }
    }
}
