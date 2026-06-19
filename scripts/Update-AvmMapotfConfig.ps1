<#
.SYNOPSIS
    Mirror (or verify) the Azure/avm-terraform-governance mapotf pre-commit
    configs vendored under config/mapotf/pre-commit/.

.DESCRIPTION
    Until Avm.Authoring ships its own canonical copy, the mapotf
    'pre-commit' transform configs (mapotf-configs/pre-commit/*.mptf.hcl in
    Azure/avm-terraform-governance) are vendored into this repo so that
    'mapotf transform --mptf-dir config/mapotf/pre-commit --tf-dir .' runs
    fully offline against a pinned, reviewed set.

    Run with no switches to (re-)mirror every config at -Ref, writing each
    file LF-normalised and UTF-8 (no BOM), overwriting the in-tree copies and
    pruning any local *.mptf.hcl that upstream no longer ships. The maintainer
    then reviews the diff and commits.

    Run with -Check to write nothing and instead fail (exit 1) when any local
    config is missing, extra, or differs from upstream at -Ref. Use it in CI
    (e.g. -Ref main) to detect that the vendored copy has drifted behind the
    governance repo.

    This script is a maintainer / CI utility. It is not on the runtime install
    path and is intentionally self-contained (no Avm.Authoring import).

.PARAMETER Ref
    Commit SHA (recommended), branch, or tag in Azure/avm-terraform-governance
    to mirror from. Defaults to the recorded pin. Re-point it (and update the
    default + config/README.md) when intentionally moving the pin.

.PARAMETER Check
    Verify-only. Do not write. Exit 1 on any drift (missing / extra / changed
    file) between the in-tree copy and upstream at -Ref.

.PARAMETER DestinationPath
    Override the local config directory. Defaults to
    <repo>/config/mapotf/pre-commit.

.PARAMETER Token
    Optional GitHub token used for the contents API (raises the anonymous
    60 req/hr rate limit). Falls back to $env:GITHUB_TOKEN then $env:GH_TOKEN.

.EXAMPLE
    ./scripts/Update-AvmMapotfConfig.ps1
    Re-mirror every config at the recorded pin and overwrite the in-tree copy.

.EXAMPLE
    ./scripts/Update-AvmMapotfConfig.ps1 -Ref main
    Move the vendored copy forward to the tip of the governance default branch.

.EXAMPLE
    ./scripts/Update-AvmMapotfConfig.ps1 -Check -Ref main
    CI drift gate: fail if the vendored copy no longer matches governance main.

.NOTES
    Sync obligation: this vendored bundle is a temporary mirror. Once
    Avm.Authoring ships and owns the canonical copy, the upstream
    mapotf-configs/pre-commit/ directory is expected to be deleted and this
    becomes the source of truth. Until then, keep them in sync via this script.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Ref = '7f8c4ee4d68095310ddd8722f9cc27d32a0de82c',

    [Parameter()]
    [switch] $Check,

    [Parameter()]
    [string] $DestinationPath = (Join-Path $PSScriptRoot '..' 'config' 'mapotf' 'pre-commit'),

    [Parameter()]
    [string] $Token
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:Owner = 'Azure'
$script:Repo = 'avm-terraform-governance'
$script:UpstreamDir = 'mapotf-configs/pre-commit'
$script:ConfigSuffix = '.mptf.hcl'

function script:Get-AuthHeader {
    $tok = $Token
    if (-not $tok) { $tok = $env:GITHUB_TOKEN }
    if (-not $tok) { $tok = $env:GH_TOKEN }
    $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'Avm.Authoring-config-sync' }
    if ($tok) { $headers['Authorization'] = "Bearer $tok" }
    return $headers
}

function script:ConvertTo-Lf {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    return ($Text -replace "`r`n", "`n") -replace "`r", "`n"
}

function script:Get-UpstreamConfig {
    # Returns an ordered list of [pscustomobject]@{ Name; Content } for every
    # *.mptf.hcl file in the upstream pre-commit dir at $Ref, LF-normalised.
    $apiUrl = "https://api.github.com/repos/$($script:Owner)/$($script:Repo)/contents/$($script:UpstreamDir)?ref=$Ref"
    Write-Host "  GET $apiUrl" -ForegroundColor DarkGray
    $headers = script:Get-AuthHeader
    $listing = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing

    $files = @($listing | Where-Object { $_.type -eq 'file' -and $_.name -like "*$($script:ConfigSuffix)" } | Sort-Object name)
    if ($files.Count -eq 0) {
        throw "No '*$($script:ConfigSuffix)' files found at $($script:Owner)/$($script:Repo)//$($script:UpstreamDir)@$Ref. Has the upstream layout changed?"
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
        $rawUrl = $f.download_url
        Write-Host "  GET $rawUrl" -ForegroundColor DarkGray
        $response = Invoke-WebRequest -Uri $rawUrl -Headers (script:Get-AuthHeader) -UseBasicParsing
        $content = $response.Content
        if ($content -is [byte[]]) {
            $content = [System.Text.Encoding]::UTF8.GetString($content)
        }
        $result.Add([pscustomobject]@{
                Name    = [string]$f.name
                Content = script:ConvertTo-Lf -Text ([string]$content)
            })
    }
    return $result
}

function script:Get-LocalConfigContent {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path)
    return script:ConvertTo-Lf -Text $raw
}

function script:Write-ConfigFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

Write-Host "mapotf pre-commit configs" -ForegroundColor Cyan
Write-Host "  source : $($script:Owner)/$($script:Repo)//$($script:UpstreamDir)@$Ref" -ForegroundColor Cyan
Write-Host "  dest   : $DestinationPath" -ForegroundColor Cyan
Write-Host "  mode   : $(if ($Check) { 'check (no writes)' } else { 'mirror' })" -ForegroundColor Cyan

$upstream = script:Get-UpstreamConfig
Write-Host "  found  : $($upstream.Count) upstream config(s)" -ForegroundColor Cyan

# Existing local set (names only) so we can detect extras / prune.
$localNames = @()
if (Test-Path -LiteralPath $DestinationPath) {
    $localNames = @(
        Get-ChildItem -LiteralPath $DestinationPath -Filter "*$($script:ConfigSuffix)" -File -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name
    )
}
$upstreamNames = @($upstream | Select-Object -ExpandProperty Name)

if ($Check) {
    $drift = [System.Collections.Generic.List[string]]::new()

    foreach ($cfg in $upstream) {
        $localPath = Join-Path $DestinationPath $cfg.Name
        $local = script:Get-LocalConfigContent -Path $localPath
        if ($null -eq $local) {
            $drift.Add("missing: $($cfg.Name) (present upstream, absent locally)")
        }
        elseif (-not [string]::Equals($local, $cfg.Content, [System.StringComparison]::Ordinal)) {
            $drift.Add("changed: $($cfg.Name) (local differs from upstream@$Ref)")
        }
    }

    foreach ($name in $localNames) {
        if ($upstreamNames -notcontains $name) {
            $drift.Add("extra:   $name (present locally, absent upstream@$Ref)")
        }
    }

    if ($drift.Count -gt 0) {
        Write-Host ""
        Write-Host "DRIFT DETECTED ($($drift.Count)):" -ForegroundColor Red
        foreach ($d in $drift) { Write-Host "  - $d" -ForegroundColor Red }
        Write-Host ""
        Write-Host "Run './scripts/Update-AvmMapotfConfig.ps1 -Ref $Ref' to re-sync, then review + commit." -ForegroundColor Yellow
        exit 1
    }

    Write-Host ""
    Write-Host "OK - vendored configs match upstream@$Ref ($($upstream.Count) file(s))." -ForegroundColor Green
    return
}

# Mirror mode.
if (-not (Test-Path -LiteralPath $DestinationPath)) {
    if ($PSCmdlet.ShouldProcess($DestinationPath, 'Create directory')) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
}

$written = 0
foreach ($cfg in $upstream) {
    $localPath = Join-Path $DestinationPath $cfg.Name
    if ($PSCmdlet.ShouldProcess($localPath, 'Write config')) {
        script:Write-ConfigFile -Path $localPath -Content $cfg.Content
        $written++
        Write-Host "  wrote  $($cfg.Name)" -ForegroundColor Green
    }
}

# Prune local configs upstream no longer ships.
foreach ($name in $localNames) {
    if ($upstreamNames -notcontains $name) {
        $stalePath = Join-Path $DestinationPath $name
        if ($PSCmdlet.ShouldProcess($stalePath, 'Remove stale config (absent upstream)')) {
            Remove-Item -LiteralPath $stalePath -Force
            Write-Host "  pruned $name (no longer upstream)" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "Mirrored $written config(s) from $($script:Owner)/$($script:Repo)//$($script:UpstreamDir)@$Ref." -ForegroundColor Green
Write-Host "Review the diff and commit. If the pin moved, update the -Ref default in this script and config/README.md." -ForegroundColor Cyan
