#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string] $ReleaseTag,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository,

    [Parameter(Mandatory = $true)]
    [long] $ReleaseId,

    [Parameter(Mandatory = $true)]
    [string] $OutputPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    throw 'GH_TOKEN is required to download release assets.'
}
if ($ReleaseId -le 0) {
    throw "Release ID '$ReleaseId' must be positive."
}

$assetsJson = gh api --paginate --slurp "repos/$Repository/releases/$ReleaseId/assets?per_page=100"
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list release assets for '$ReleaseTag' (release ID $ReleaseId)."
}

$assetPages = ConvertFrom-Json -InputObject $assetsJson -NoEnumerate
$assets = @(
    foreach ($page in $assetPages) {
        foreach ($asset in $page) {
            $asset
        }
    }
)

$requiredNames = @("Avm.Authoring-$($ReleaseTag.Substring(1)).zip", 'SHA256SUMS')
$selectedAssets = @(
    foreach ($name in $requiredNames) {
        $candidates = @($assets | Where-Object { $_.name -ceq $name })
        if ($candidates.Count -ne 1) {
            throw "Expected exactly one release asset '$name' for '$ReleaseTag'; found $($candidates.Count)."
        }

        $asset = $candidates[0]
        if ($asset.state -cne 'uploaded' -or [long] $asset.id -le 0 -or [long] $asset.size -le 0) {
            throw "Release asset '$name' is not a complete upload."
        }
        $asset
    }
)

if (-not $PSCmdlet.ShouldProcess($OutputPath, "Download signed release assets for '$ReleaseTag'")) {
    return
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$headers = @{
    Accept = 'application/octet-stream'
    Authorization = "Bearer $env:GH_TOKEN"
}
foreach ($asset in $selectedAssets) {
    $targetPath = Join-Path $OutputPath $asset.name
    Invoke-WebRequest `
        -Uri "https://api.github.com/repos/$Repository/releases/assets/$($asset.id)" `
        -Headers $headers `
        -OutFile $targetPath

    $actualSize = (Get-Item -LiteralPath $targetPath).Length
    if ($actualSize -ne [long] $asset.size) {
        throw "Release asset '$($asset.name)' has size $actualSize; expected $($asset.size)."
    }
}
