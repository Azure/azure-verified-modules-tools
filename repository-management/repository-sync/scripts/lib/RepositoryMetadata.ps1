#Requires -Version 7.4

function Get-RepositoryModuleMetadata {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DefaultBranch,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $reference = [uri]::EscapeDataString($DefaultBranch)
    $response = Invoke-RepositorySyncProcess -Command gh -Arguments @(
        'api', '--hostname', 'github.com', '--method', 'GET',
        '--header', 'Accept: application/vnd.github+json',
        '--header', 'X-GitHub-Api-Version: 2022-11-28',
        "repos/$Repository/contents/metadata.json?ref=$reference"
    )
    if ($response.ExitCode -ne 0) {
        if ($response.StdErr -match '\(HTTP 404\)') {
            return [pscustomobject]@{ Status = 'missing'; Metadata = $null }
        }
        throw [System.InvalidOperationException]::new(
            "Cannot read $Repository/metadata.json on '$DefaultBranch': $($response.StdErr)"
        )
    }

    $file = $response.StdOut | ConvertFrom-Json -AsHashtable -Depth 64
    if ($file -isnot [System.Collections.IDictionary] -or
        $file.type -cne 'file' -or $file.path -cne 'metadata.json' -or
        $file.encoding -cne 'base64' -or $file.sha -cnotmatch '^[0-9a-f]{40}$' -or
        $file.size -lt 0) {
        throw [System.IO.InvalidDataException]::new("GitHub did not return a complete regular metadata.json file for $Repository.")
    }
    $bytes = [System.Convert]::FromBase64String($file.content)
    if ($bytes.Length -ne $file.size -or (Get-RepositoryGitBlobSha -Bytes $bytes) -cne $file.sha) {
        throw [System.IO.InvalidDataException]::new("GitHub metadata.json size or blob SHA mismatch for $Repository.")
    }
    $json = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $module = Get-Module Avm.Authoring | Select-Object -First 1
    $validation = & $module {
        param($Json, $ModuleType)
        Test-AvmMetadataContent -Json $Json -Ecosystem terraform -ModuleType $ModuleType
    } $json $ModuleType
    if ($validation.Issues.Count -gt 0) {
        throw [System.IO.InvalidDataException]::new(
            "Invalid $Repository/metadata.json: $($validation.Issues.Message -join ' ')"
        )
    }
    return [pscustomobject]@{ Status = 'pass'; Metadata = $validation.Metadata }
}
