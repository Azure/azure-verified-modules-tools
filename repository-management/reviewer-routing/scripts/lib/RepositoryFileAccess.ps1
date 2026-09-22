#Requires -Version 7.4

# Generic, integrity-verified single-file read through the GitHub contents
# API. Reused for both the published module catalog (ref = a branch name)
# and per-module metadata.json at a pull request head commit (ref = a SHA),
# so both call sites get the same base64/size/blob-SHA verification and
# graceful 404 handling.
#
# The contents API only inlines base64 content for files up to 1 MB; larger
# files (the published module catalog is ~1.7 MB) come back with
# encoding = 'none' and an empty content field. For those, a second request
# using the 'application/vnd.github.raw+json' media type fetches the actual
# bytes, which are then verified against the first response's size/blob SHA
# exactly as the inline base64 path is.

function Get-AvmRepositoryFileAtRef {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Ref,
        [switch] $AllowMissing
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $encodedRef = [uri]::EscapeDataString($Ref)
    $resource = "repos/$Repository/contents/$Path`?ref=$encodedRef"
    $response = Invoke-RepositorySyncProcess -Command gh -Arguments @(
        'api', '--hostname', 'github.com', '--method', 'GET',
        '--header', 'Accept: application/vnd.github+json',
        '--header', 'X-GitHub-Api-Version: 2022-11-28',
        $resource
    )
    if ($response.ExitCode -ne 0) {
        if ($AllowMissing -and $response.StdErr -match '\(HTTP 404\)') {
            return $null
        }
        throw [System.InvalidOperationException]::new(
            "Cannot read $Repository/$Path at '$Ref': $($response.StdErr)"
        )
    }

    $file = $response.StdOut | ConvertFrom-Json -AsHashtable -Depth 64
    if ($file -isnot [System.Collections.IDictionary] -or
        $file.type -cne 'file' -or $file.path -cne $Path -or
        $file.sha -cnotmatch '^[0-9a-f]{40}$' -or $file.size -lt 0 -or
        ($file.encoding -cne 'base64' -and $file.encoding -cne 'none')) {
        throw [System.IO.InvalidDataException]::new("GitHub did not return a complete regular file for $Repository/$Path.")
    }

    if ($file.encoding -ceq 'base64') {
        $bytes = [System.Convert]::FromBase64String($file.content)
    } else {
        $rawResponse = Invoke-RepositorySyncProcess -Command gh -Arguments @(
            'api', '--hostname', 'github.com', '--method', 'GET',
            '--header', 'Accept: application/vnd.github.raw+json',
            '--header', 'X-GitHub-Api-Version: 2022-11-28',
            $resource
        )
        if ($rawResponse.ExitCode -ne 0) {
            throw [System.InvalidOperationException]::new(
                "Cannot read raw content for $Repository/$Path at '$Ref': $($rawResponse.StdErr)"
            )
        }
        $bytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($rawResponse.StdOut)
    }

    if ($bytes.Length -ne $file.size -or (Get-RepositoryGitBlobSha -Bytes $bytes) -cne $file.sha) {
        throw [System.IO.InvalidDataException]::new("GitHub file size or blob SHA mismatch for $Repository/$Path.")
    }

    return [pscustomobject]@{
        Content = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        Sha = $file.sha
    }
}
