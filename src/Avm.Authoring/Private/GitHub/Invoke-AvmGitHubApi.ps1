function Invoke-AvmGitHubApi {
    <#
    .SYNOPSIS
        Call the GitHub REST API on github.com through the authenticated GitHub CLI.
    .DESCRIPTION
        Returns the parsed JSON response as hashtables. List responses are
        written to the pipeline one item at a time, so wrap list calls in @().
        Request bodies are sent as JSON through a temporary file. Failures
        throw AvmGitHubException carrying the HTTP status that gh reported.
    .PARAMETER Endpoint
        REST path relative to https://api.github.com, including any query string.
    .PARAMETER Method
        HTTP method.
    .PARAMETER Body
        Object serialized to the JSON request body.
    .PARAMETER AllowNotFound
        Return $null instead of throwing when GitHub responds 404.
    .PARAMETER Accept
        Media type requested from GitHub.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string] $Endpoint,

        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string] $Method = 'GET',

        [object] $Body,

        [switch] $AllowNotFound,

        [string] $Accept = 'application/vnd.github+json'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $gh = Get-AvmApplicationPath -Name gh
    $arguments = @(
        'api', '--hostname', 'github.com', '--method', $Method,
        '--header', "Accept: $Accept",
        '--header', 'X-GitHub-Api-Version: 2022-11-28',
        $Endpoint
    )
    $bodyPath = $null
    try {
        if ($PSBoundParameters.ContainsKey('Body')) {
            $bodyPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath (
                'avm-github-' + [guid]::NewGuid().ToString('N') + '.json')
            $json = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
            [System.IO.File]::WriteAllText($bodyPath, $json, [System.Text.UTF8Encoding]::new($false))
            $arguments += @('--input', $bodyPath)
        }
        $result = Invoke-AvmProcess -FilePath $gh -ArgumentList $arguments -IgnoreExitCode `
            -RetryNetworkFailure:($Method -eq 'GET') `
            -Label "gh api $Method $Endpoint" `
            -EnvVars @{ GH_HOST = 'github.com'; GH_PROMPT_DISABLED = '1'; GH_DEBUG = $null; NO_COLOR = '1' }
    }
    finally {
        if ($bodyPath -and [System.IO.File]::Exists($bodyPath)) {
            [System.IO.File]::Delete($bodyPath)
        }
    }

    if ($result.ExitCode -eq 0) {
        if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
            return $null
        }
        return ConvertFrom-Json -InputObject $result.StdOut -AsHashtable
    }

    $statusCode = 0
    $statusMatch = [regex]::Match([string]$result.StdErr, '\(HTTP (?<code>\d{3})\)')
    if ($statusMatch.Success) {
        $statusCode = [int]$statusMatch.Groups['code'].Value
    }
    if ($statusCode -eq 404 -and $AllowNotFound) {
        return $null
    }

    $details = [System.Collections.Generic.List[string]]::new()
    try {
        $errorBody = ConvertFrom-Json -InputObject ([string]$result.StdOut) -AsHashtable -ErrorAction Stop
        if ($errorBody -is [System.Collections.IDictionary]) {
            if ($errorBody['message']) {
                $details.Add([string]$errorBody['message'])
            }
            foreach ($item in @($errorBody['errors'])) {
                if ($item -is [System.Collections.IDictionary] -and $item['message']) {
                    $details.Add([string]$item['message'])
                }
                elseif ($item -is [string]) {
                    $details.Add($item)
                }
            }
        }
    }
    catch {
        Write-AvmLog ('github: response was not JSON: {0}' -f $_.Exception.Message) -Level Verbose | Out-Null
    }
    if ($details.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.StdErr)) {
        $details.Add($result.StdErr.Trim())
    }
    $statusText = if ($statusCode -gt 0) { " with HTTP $statusCode" } else { '' }
    throw [AvmGitHubException]::new(
        "GitHub API $Method $Endpoint failed$statusText`: $($details -join ' ')", $statusCode)
}
