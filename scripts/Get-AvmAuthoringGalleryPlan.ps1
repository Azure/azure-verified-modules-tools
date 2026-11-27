#Requires -Version 7.4

[CmdletBinding()]
param([string] $ReleaseTag)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$stableTag = '\Av[0-9]+\.[0-9]+\.[0-9]+\z'
if ($ReleaseTag -and $ReleaseTag -cnotmatch $stableTag) {
    throw "Release tag must match vMAJOR.MINOR.PATCH."
}

$fullReleases = @(
    gh api --paginate "repos/$env:GITHUB_REPOSITORY/releases?per_page=100" `
        --jq '.[] | select(.draft == false and .prerelease == false and .published_at != null) | .tag_name' |
        Where-Object { $_ -cmatch $stableTag }
)
if ($ReleaseTag) {
    if ($fullReleases -cnotcontains $ReleaseTag) {
        throw "'$ReleaseTag' must be an existing published full GitHub release."
    }
    $fullReleases = @($ReleaseTag)
}

$mcr = Invoke-RestMethod -Uri 'https://mcr.microsoft.com/v2/psresource/avm.authoring/tags/list' `
    -MaximumRetryCount 3 -TimeoutSec 30
if ($mcr.name -cne 'psresource/avm.authoring' -or $null -eq $mcr.tags) {
    throw 'Unexpected Avm.Authoring tag response from MCR.'
}
$ready = @($fullReleases | Where-Object { $mcr.tags -ccontains $_.Substring(1) })
if ($ReleaseTag -and $ready.Count -eq 0) {
    throw "'$ReleaseTag' is not available in MCR yet."
}

$pending = @()
if ($ready.Count -gt 0) {
    . (Join-Path $PSScriptRoot 'Import-AvmNetworkRetry.ps1')
    foreach ($tag in $ready | Select-Object -Unique) {
        $version = $tag.Substring(1)
        $existing = Invoke-AvmRetry `
            -RetryActivity "Checking whether Avm.Authoring $version is published on PSGallery" `
            -RetryAction {
                $findErrors = $null
                $found = Find-PSResource -Name Avm.Authoring -Version $version -Repository PSGallery `
                    -ErrorAction SilentlyContinue -ErrorVariable findErrors
                foreach ($findError in @($findErrors)) {
                    if ((Get-AvmNetworkFailureKind -ErrorRecord $findError) -eq 'Transient') {
                        throw $findError
                    }
                    $notFound = $findError.Exception.Message -match '(?i)\bPackage does not exist on the server\b' -or
                        $findError.Exception.Message -eq "Package with name 'Avm.Authoring', version '$version' could not be found in repository 'PSGallery'."
                    if (-not $notFound) {
                        throw $findError
                    }
                }
                $found
            }
        if (-not $existing) {
            $pending += $tag
        }
    }
}

Write-Host "Found $($pending.Count) full release(s) in MCR not yet on PSGallery."
"tags=$($pending -join ',')" >> $env:GITHUB_OUTPUT
