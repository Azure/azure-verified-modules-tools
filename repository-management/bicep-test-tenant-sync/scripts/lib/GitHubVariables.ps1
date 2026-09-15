function Get-AvmBicepTestTenantVariableNames {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    'TEST_BAMI_TENANT_ID'
    'TEST_BAMI_BICEP_CLIENT_ID'
    'TEST_BAMI_SUBSCRIPTION_IDS'
    'TEST_BAMI_MANAGEMENT_GROUP_ID'
    'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID'
    'TEST_BAMI_MODULE_PATHS'
}

function Invoke-AvmBicepTestTenantVariableApi {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', IgnoreCase = $false)] [string] $Method = 'GET',
        [ValidateSet(
            'TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_SUBSCRIPTION_IDS',
            'TEST_BAMI_MANAGEMENT_GROUP_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID',
            'TEST_BAMI_MODULE_PATHS', IgnoreCase = $false
        )] [string] $Name,
        [AllowEmptyString()] [string] $Value,
        [ValidateRange(1, 10000)] [int] $Page = 1
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Method -ceq 'GET') {
        if ($PSBoundParameters.ContainsKey('Name') -or $PSBoundParameters.ContainsKey('Value')) {
            throw [System.ArgumentException]::new('Variable snapshots read the repository variable collection, not an individual value.')
        }
    }
    elseif (-not $Name -or -not $PSBoundParameters.ContainsKey('Value') -or $PSBoundParameters.ContainsKey('Page')) {
        throw [System.ArgumentException]::new('A variable write requires an allowed name and explicit value, without pagination.')
    }
    if ($env:AVM_OFFLINE -ceq '1') {
        throw [System.InvalidOperationException]::new('AVM_OFFLINE=1: refusing GitHub variable operations.')
    }
    $token = $env:GH_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw [System.InvalidOperationException]::new('Bicep variable synchronization requires an explicit target-scoped app installation token in GH_TOKEN.')
    }
    if ($Method -cne 'GET' -and -not $PSCmdlet.ShouldProcess("Azure/bicep-registry-modules/$Name", 'Write a nonsecret Actions variable')) {
        throw [System.OperationCanceledException]::new('The nonsecret variable write was not approved.')
    }

    $endpoint = 'repos/Azure/bicep-registry-modules/actions/variables'
    if ($Method -ceq 'GET') { $endpoint += "?per_page=100&page=$Page" }
    elseif ($Method -ceq 'PATCH') { $endpoint += "/$Name" }
    $arguments = @(
        'api', '--hostname', 'github.com', '--method', $Method,
        '--header', 'Accept: application/vnd.github+json',
        '--header', 'X-GitHub-Api-Version: 2022-11-28',
        '--header', 'Cache-Control: no-cache', $endpoint
    )
    if ($Method -cne 'GET') {
        $arguments += @('--raw-field', "name=$Name", '--raw-field', "value=$Value")
    }
    # Do not retry writes: a lost response can hide a successful mutation.
    $response = Invoke-RepositorySyncProcess -Command 'gh' -Arguments $arguments -TimeoutSec 60 -EnvVars @{
        GH_TOKEN = $token
        GH_ENTERPRISE_TOKEN = $null
        GITHUB_ENTERPRISE_TOKEN = $null
    }
    if ($response.ExitCode -ne 0) {
        $httpStatus = [regex]::Match([string]$response.StdErr, '\(HTTP ([0-9]{3})\)')
        $detail = if ($httpStatus.Success) { "; HTTP $($httpStatus.Groups[1].Value)" } else { '' }
        throw [System.InvalidOperationException]::new("GitHub variable $Method $Name failed (exit $($response.ExitCode)$detail).")
    }
    if ($Method -ceq 'GET') {
        if ([string]::IsNullOrWhiteSpace($response.StdOut)) {
            throw [System.IO.InvalidDataException]::new('GitHub returned an empty variable collection response.')
        }
        try {
            return ConvertFrom-Json -InputObject $response.StdOut -AsHashtable -NoEnumerate -ErrorAction Stop
        }
        catch {
            throw [System.IO.InvalidDataException]::new('GitHub returned invalid variable collection JSON.', $_.Exception)
        }
    }
}

function Get-AvmBicepTestTenantSnapshot {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $snapshot = [ordered]@{}
    foreach ($name in Get-AvmBicepTestTenantVariableNames) { $snapshot[$name] = $null }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $total = $null
    $page = 1
    do {
        $response = Invoke-AvmBicepTestTenantVariableApi -Page $page
        if ($response -isnot [System.Collections.IDictionary] -or -not $response.Contains('total_count') -or
            -not $response.Contains('variables') -or $response['variables'] -isnot [array] -or
            ($response['total_count'] -isnot [long] -and $response['total_count'] -isnot [int]) -or
            $response['total_count'] -lt 0 -or $response['variables'].Count -gt 100) {
            throw [System.IO.InvalidDataException]::new('GitHub returned a malformed variable collection.')
        }
        if ($null -eq $total) { $total = $response['total_count'] }
        if ($total -ne $response['total_count']) {
            throw [System.IO.InvalidDataException]::new('The variable collection changed during pagination.')
        }
        foreach ($variable in $response['variables']) {
            if ($variable -isnot [System.Collections.IDictionary] -or -not $variable.Contains('name') -or
                $variable['name'] -isnot [string] -or [string]::IsNullOrWhiteSpace($variable['name']) -or
                -not $seen.Add($variable['name'])) {
                throw [System.IO.InvalidDataException]::new('GitHub returned missing or duplicate variable names.')
            }
            $name = $variable['name']
            if (-not $snapshot.Contains($name)) { continue }
            if ($name -cnotin @(Get-AvmBicepTestTenantVariableNames) -or -not $variable.Contains('value') -or
                $variable['value'] -isnot [string]) {
                throw [System.IO.InvalidDataException]::new('GitHub returned a malformed candidate variable.')
            }
            $timestamps = @{}
            foreach ($field in @('created_at', 'updated_at')) {
                if (-not $variable.Contains($field)) {
                    throw [System.IO.InvalidDataException]::new("GitHub omitted $field for $name.")
                }
                $timestamp = $variable[$field]
                $parsed = [datetimeoffset]::MinValue
                if ($timestamp -is [datetime]) {
                    $timestamps[$field] = $timestamp.ToUniversalTime().ToString('O', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                elseif ($timestamp -is [string] -and [datetimeoffset]::TryParse(
                    $timestamp, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed
                )) {
                    $timestamps[$field] = $parsed.UtcDateTime.ToString('O', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    throw [System.IO.InvalidDataException]::new("GitHub returned an invalid $field for $name.")
                }
            }
            $snapshot[$name] = [pscustomobject]@{
                Name = $name
                Value = $variable['value']
                CreatedAt = $timestamps['created_at']
                UpdatedAt = $timestamps['updated_at']
            }
        }
        if ($seen.Count -gt $total -or ($response['variables'].Count -lt 100 -and $seen.Count -ne $total)) {
            throw [System.IO.InvalidDataException]::new('GitHub returned an incomplete or inconsistent variable collection.')
        }
        $page++
    } while ($seen.Count -lt $total)
    return $snapshot
}
