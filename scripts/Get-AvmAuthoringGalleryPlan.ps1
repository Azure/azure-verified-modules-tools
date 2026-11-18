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
    $published = @(Invoke-AvmRetry -RetryActivity 'Listing Avm.Authoring versions on PSGallery' -RetryAction {
        Find-PSResource -Name Avm.Authoring -Version '*' -Repository PSGallery |
            ForEach-Object { $_.Version.ToString() }
    })
    $pending = @($ready | Where-Object { $published -cnotcontains $_.Substring(1) } | Select-Object -Unique)
}

Write-Host "Found $($pending.Count) full release(s) in MCR not yet on PSGallery."
"tags=$($pending -join ',')" >> $env:GITHUB_OUTPUT
