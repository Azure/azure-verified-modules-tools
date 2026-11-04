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

    if ($Type -ieq 'Microsoft.Management/managementGroups') {
        return @()
    }

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
    $providerSegments = [regex]::Matches($inputParameters.Scope, '/providers/', 'IgnoreCase').Count
    if ($providerSegments -gt 1) {
        $path = $inputParameters.Scope + '/providers/Microsoft.Authorization/locks'
        $next = $path + '?api-version=2016-09-01'
        $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $locks = @(
            while ($next) {
                if (-not $visited.Add($next) -or $visited.Count -gt 40) {
                    throw [AvmProcessException]::new('Resource lock pagination exceeded its limit.')
                }
                $response = Invoke-AzRestMethod -Method GET -Path $next -ErrorAction Stop
                $status = Get-AvmPropertyValue -InputObject $response -Name 'StatusCode' -NoEnumerate
                if ($visited.Count -eq 1 -and ($status -is [int] -or $status -is [System.Net.HttpStatusCode]) -and [int]$status -eq 404) {
                    break
                }
                $document = ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Read resource locks'
                if ($document['value'] -isnot [array]) {
                    throw [AvmProcessException]::new('Resource lock response did not contain a value array.')
                }
                foreach ($entry in $document['value']) {
                    [pscustomobject]@{ LockId = Get-AvmPropertyValue -InputObject $entry -Name 'id' -NoEnumerate; UseRest = $true }
                }
                $next = Resolve-AvmBicepCleanupNextLink -ExpectedPath $path -NextLink (
                    Get-AvmPropertyValue -InputObject $document -Name 'nextLink' -NoEnumerate)
            }
        )
    }
    else {
        try {
            $locks = @(Get-AzResourceLock @inputParameters)
        }
        catch {
            if ((Get-AvmBicepAzureErrorStatus -ErrorRecord $_) -eq 404) {
                return @()
            }
            throw
        }
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
            if ($providerSegments -gt 1) {
                $parsed = @(ConvertTo-AvmBicepCleanupResource -ResourceIds @($lockId))
                if ($parsed.Count -ne 1 -or $parsed[0].type -ine 'Microsoft.Authorization/locks') {
                    throw [AvmProcessException]::new("Azure returned an invalid resource lock ID for '$ResourceId'.")
                }
            }
            $lock
        }
        else {
            Write-AvmLog "Leaving lock '$lockId' outside cleanup target '$ResourceId'." -Level Warning
        }
    }
}
