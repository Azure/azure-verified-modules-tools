<#
.SYNOPSIS
    Refresh src/Avm.Authoring/Resources/avm.pins.jsonc with verified
    per-platform SHA256 hashes for canonical AVM CLI dependencies.

.DESCRIPTION
    The script fetches official checksums or downloads the per-platform
    asset and computes the SHA256 locally, then merges the resulting
    entries into the lock file (preserving entries for tools you didn't
    name). The file is rewritten with deterministic formatting so diffs
    are minimal.

    Currently supported tools:
      - terraform     : uses 'terraform_<v>_SHA256SUMS' published on
                        releases.hashicorp.com. Fast, no large downloads.
      - tflint        : uses 'checksums.txt' published on the terraform-linters
                        GitHub release page. Fast, no large downloads.
      - terraform-docs: uses 'terraform-docs-v<v>.sha256sum' published on the
                        terraform-docs GitHub release page. Mixed archives
                        (tar.gz for darwin/linux, zip for windows).
      - conftest      : uses 'checksums.txt' published on the open-policy-agent
                        GitHub release page. Title-cased OS + x86_64 arch
                        naming, mixed archives (tar.gz for darwin/linux, zip
                        for windows) - first lock entry that needs
                        platformAliases AND archives together.
      - mapotf        : uses 'checksums.txt' published on the Azure/mapotf
                        GitHub release page. Mixed archives (tar.gz for
                        darwin/linux, zip for windows).
      - bicep         : downloads each of the six per-platform binaries from
                        https://github.com/Azure/bicep/releases/download/v<v>/.
                        Each binary is ~10-20 MB, so the whole pass needs
                        ~80-120 MB of network. Cancellable.

    The script never publishes anything; it only mutates a single .jsonc
    file under source control. The resulting lock is then validated via
    Test-AvmPins by importing the Avm.Authoring module.

.PARAMETER Terraform
    Terraform version to lock, e.g. '1.15.8'. Skip the terraform tool when
    omitted.

.PARAMETER Bicep
    Bicep version to lock, e.g. '0.46.1' (no leading 'v'). Skip the bicep
    tool when omitted.

.PARAMETER Tflint
    Tflint version to lock, e.g. '0.64.0' (no leading 'v'). Skip the tflint
    tool when omitted.

.PARAMETER TerraformDocs
    terraform-docs version to lock, e.g. '0.24.0' (no leading 'v'). Skip
    the terraform-docs tool when omitted.

.PARAMETER Conftest
    conftest version to lock, e.g. '0.69.0' (no leading 'v'). Skip the
    conftest tool when omitted.

.PARAMETER Mapotf
    mapotf version to lock, e.g. '0.1.10' (no leading 'v'). Skip the mapotf
    tool when omitted.

.PARAMETER PolicyLibrary
    Azure/policy-library-avm tag to pin, e.g. 'v1.0.0' (leading 'v' required).
    Downloads the source tarball and records its SHA256.

.PARAMETER TflintPlugin
    Hashtable of TFLint plugin name to version, e.g. @{ avm = '0.17.0' }.
    Updates the mirrored versions in the manifest only; the authoritative
    copy in Resources/tflint/*.hcl must be edited by hand to match, and a
    packaging test asserts the two agree.

.PARAMETER PinsPath
    Override the path to avm.pins.jsonc. Defaults to the in-tree copy
    under src/Avm.Authoring/Resources/.

.PARAMETER WhatIf
    Show what would change without writing the file.

.EXAMPLE
    ./scripts/Update-AvmPins.ps1 -Terraform 1.15.8 -Bicep 0.46.1

.EXAMPLE
    ./scripts/Update-AvmPins.ps1 -Terraform 1.9.8

.EXAMPLE
    ./scripts/Update-AvmPins.ps1 -Conftest 0.69.0 -Mapotf 0.1.10

.NOTES
    Intended for maintainers and CI 'refresh tools' workflows. Not part
    of the runtime install path.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $Terraform,

    [Parameter()]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $Bicep,

    [Parameter()]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $Tflint,

    [Parameter()]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $TerraformDocs,

    [Parameter()]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $Conftest,

    [Parameter()]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $Mapotf,

    [Parameter()]
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $PolicyLibrary,

    [Parameter()]
    [hashtable] $TflintPlugin = @{},

    [Parameter()]
    [string] $PinsPath = (Join-Path $PSScriptRoot '..' 'src' 'Avm.Authoring' 'Resources' 'avm.pins.jsonc')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $Terraform -and -not $Bicep -and -not $Tflint -and -not $TerraformDocs -and
    -not $Conftest -and -not $Mapotf -and -not $PolicyLibrary -and $TflintPlugin.Count -eq 0) {
    throw "Specify at least one of -Terraform, -Bicep, -Tflint, -TerraformDocs, -Conftest, -Mapotf, -PolicyLibrary <vX.Y.Z> or -TflintPlugin @{ name = 'version' }."
}

$PinsPath = (Resolve-Path -LiteralPath $PinsPath).Path
Write-Host "Pin manifest: $PinsPath" -ForegroundColor Cyan

function script:Read-PinsFile {
    param([Parameter(Mandatory)] [string] $Path)
    # ConvertFrom-Json natively tolerates JSONC line/block comments and
    # trailing commas, so no pre-processing is needed.
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable)
}

# ----------------------------------------------------------------------
# Platform map shared by every tool entry. Keys are the canonical platform
# tags used everywhere in the codebase.
# ----------------------------------------------------------------------
$script:platforms = @(
    'windows-amd64'
    'windows-arm64'
    'linux-amd64'
    'linux-arm64'
    'darwin-amd64'
    'darwin-arm64'
)

function script:Invoke-HttpGet {
    param([Parameter(Mandatory)] [string] $Url)
    Write-Host "  GET $Url" -ForegroundColor DarkGray
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing
    $content = $response.Content
    if ($content -is [byte[]]) {
        # Some servers (e.g. GitHub release assets) omit a charset header,
        # so Invoke-WebRequest returns the body as raw bytes. Treat as UTF-8.
        return [System.Text.Encoding]::UTF8.GetString($content)
    }
    return [string]$content
}

function script:Save-Url {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Destination
    )
    Write-Host "  GET $Url" -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

function script:Get-FileHashHex {
    param([Parameter(Mandatory)] [string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# ----------------------------------------------------------------------
# Terraform: fetch the canonical SHA256SUMS file and parse the lines we
# care about. The file is small (a few KB).
# ----------------------------------------------------------------------
function script:Get-TerraformEntry {
    param([Parameter(Mandatory)] [string] $Version)

    Write-Host "Terraform $Version" -ForegroundColor Cyan
    $shaUrl = "https://releases.hashicorp.com/terraform/$Version/terraform_${Version}_SHA256SUMS"
    $body = script:Invoke-HttpGet -Url $shaUrl

    # Each line: '<hex>  terraform_<ver>_<os>_<arch>.zip'
    $sha = [ordered]@{}
    $tfPlatformMap = @{
        'windows-amd64' = 'windows_amd64'
        'windows-arm64' = 'windows_arm64'
        'linux-amd64'   = 'linux_amd64'
        'linux-arm64'   = 'linux_arm64'
        'darwin-amd64'  = 'darwin_amd64'
        'darwin-arm64'  = 'darwin_arm64'
    }
    foreach ($p in $script:platforms) {
        $needle = "terraform_${Version}_$($tfPlatformMap[$p]).zip"
        $line = ($body -split "`n") | Where-Object { $_ -match "\s$([Regex]::Escape($needle))\s*$" } | Select-Object -First 1
        if (-not $line) {
            throw "Terraform $Version SHA256SUMS did not contain entry for $needle (URL: $shaUrl)."
        }
        $hash = ($line -split '\s+')[0].ToLowerInvariant()
        if ($hash -notmatch '^[0-9a-f]{64}$') {
            throw "Parsed unexpected hash '$hash' for $needle."
        }
        $sha[$p] = $hash
        Write-Host ("    {0,-15} {1}" -f $p, $hash)
    }

    return [ordered]@{
        name        = 'terraform'
        version     = $Version
        urlTemplate = 'https://releases.hashicorp.com/terraform/{version}/terraform_{version}_{os}_{arch}.zip'
        archive     = 'zip'
        entrypoint  = 'terraform'
        sha256      = $sha
    }
}

# ----------------------------------------------------------------------
# Tflint: fetches checksums.txt from the GitHub release and parses the
# six per-platform zip lines we care about. Released as
#   tflint_<os>_<arch>.zip   - extracted entrypoint is 'tflint' (or .exe).
# ----------------------------------------------------------------------
function script:Get-TflintEntry {
    param([Parameter(Mandatory)] [string] $Version)

    Write-Host "Tflint $Version" -ForegroundColor Cyan
    $shaUrl = "https://github.com/terraform-linters/tflint/releases/download/v$Version/checksums.txt"
    $body = script:Invoke-HttpGet -Url $shaUrl

    $tfPlatformMap = @{
        'windows-amd64' = 'windows_amd64'
        'linux-amd64'   = 'linux_amd64'
        'linux-arm64'   = 'linux_arm64'
        'darwin-amd64'  = 'darwin_amd64'
        'darwin-arm64'  = 'darwin_arm64'
    }
    # tflint does not currently ship a windows-arm64 build, so the lock
    # marks that platform as unsupported and Resolve-AvmTool / Install-AvmTool
    # surface a clean AVM1012 if a Windows-on-ARM64 user runs `avm tool install tflint`.
    $unsupportedPlatforms = @('windows-arm64')
    $sha = [ordered]@{}
    foreach ($p in $script:platforms) {
        if ($unsupportedPlatforms -contains $p) { continue }
        $needle = "tflint_$($tfPlatformMap[$p]).zip"
        $line = ($body -split "`n") | Where-Object { $_ -match "\s$([Regex]::Escape($needle))\s*$" } | Select-Object -First 1
        if (-not $line) {
            throw "Tflint $Version checksums.txt did not contain entry for $needle (URL: $shaUrl)."
        }
        $hash = ($line -split '\s+')[0].ToLowerInvariant()
        if ($hash -notmatch '^[0-9a-f]{64}$') {
            throw "Parsed unexpected hash '$hash' for $needle."
        }
        $sha[$p] = $hash
        Write-Host ("    {0,-15} {1}" -f $p, $hash)
    }

    return [ordered]@{
        name                 = 'tflint'
        version              = $Version
        urlTemplate          = 'https://github.com/terraform-linters/tflint/releases/download/v{version}/tflint_{os}_{arch}.zip'
        archive              = 'zip'
        entrypoint           = 'tflint'
        unsupportedPlatforms = $unsupportedPlatforms
        sha256               = $sha
    }
}

# ----------------------------------------------------------------------
# terraform-docs: fetches 'terraform-docs-v<v>.sha256sum' from the GitHub
# release. Releases mix archive types - darwin/linux ship .tar.gz, windows
# ships .zip - so the entry uses the optional per-platform 'archives' map
# and a {ext} placeholder in urlTemplate.
# ----------------------------------------------------------------------
function script:Get-TerraformDocsEntry {
    param([Parameter(Mandatory)] [string] $Version)

    Write-Host "terraform-docs $Version" -ForegroundColor Cyan
    $shaUrl = "https://github.com/terraform-docs/terraform-docs/releases/download/v$Version/terraform-docs-v$Version.sha256sum"
    $body = script:Invoke-HttpGet -Url $shaUrl

    # darwin/linux use tar.gz, windows uses zip. terraform-docs does ship
    # a windows-arm64 zip these days so all six platforms are supported.
    $archiveMap = [ordered]@{
        'windows-amd64' = 'zip'
        'windows-arm64' = 'zip'
        'linux-amd64'   = 'tar.gz'
        'linux-arm64'   = 'tar.gz'
        'darwin-amd64'  = 'tar.gz'
        'darwin-arm64'  = 'tar.gz'
    }
    $sha = [ordered]@{}
    foreach ($p in $script:platforms) {
        $ext = if ($archiveMap[$p] -eq 'zip') { '.zip' } else { '.tar.gz' }
        $needle = "terraform-docs-v$Version-$p$ext"
        $line = ($body -split "`n") | Where-Object { $_ -match "\s$([Regex]::Escape($needle))\s*$" } | Select-Object -First 1
        if (-not $line) {
            throw "terraform-docs $Version sha256sum did not contain entry for $needle (URL: $shaUrl)."
        }
        $hash = ($line -split '\s+')[0].ToLowerInvariant()
        if ($hash -notmatch '^[0-9a-f]{64}$') {
            throw "Parsed unexpected hash '$hash' for $needle."
        }
        $sha[$p] = $hash
        Write-Host ("    {0,-15} {1}" -f $p, $hash)
    }

    return [ordered]@{
        name        = 'terraform-docs'
        version     = $Version
        urlTemplate = 'https://github.com/terraform-docs/terraform-docs/releases/download/v{version}/terraform-docs-v{version}-{os}-{arch}{ext}'
        archive     = 'tar.gz'
        archives    = $archiveMap
        entrypoint  = 'terraform-docs'
        sha256      = $sha
    }
}

# ----------------------------------------------------------------------
# conftest: fetches 'checksums.txt' from the GitHub release. Asset
# filenames use Title-cased OS (Windows/Linux/Darwin) and x86_64/arm64
# arch (not the lowercase {os}-{arch} the lock's default placeholders
# emit), plus a mixed archive map (.zip on Windows, .tar.gz elsewhere),
# so the entry combines platformAliases AND archives - the first lock
# entry to need both maps together.
# ----------------------------------------------------------------------
function script:Get-ConftestEntry {
    param([Parameter(Mandatory)] [string] $Version)

    Write-Host "conftest $Version" -ForegroundColor Cyan
    $shaUrl = "https://github.com/open-policy-agent/conftest/releases/download/v$Version/checksums.txt"
    $body = script:Invoke-HttpGet -Url $shaUrl

    $aliasMap = [ordered]@{
        'windows-amd64' = 'Windows_x86_64'
        'windows-arm64' = 'Windows_arm64'
        'linux-amd64'   = 'Linux_x86_64'
        'linux-arm64'   = 'Linux_arm64'
        'darwin-amd64'  = 'Darwin_x86_64'
        'darwin-arm64'  = 'Darwin_arm64'
    }
    $archiveMap = [ordered]@{
        'windows-amd64' = 'zip'
        'windows-arm64' = 'zip'
        'linux-amd64'   = 'tar.gz'
        'linux-arm64'   = 'tar.gz'
        'darwin-amd64'  = 'tar.gz'
        'darwin-arm64'  = 'tar.gz'
    }
    $sha = [ordered]@{}
    foreach ($p in $script:platforms) {
        $ext = if ($archiveMap[$p] -eq 'zip') { '.zip' } else { '.tar.gz' }
        $needle = "conftest_${Version}_$($aliasMap[$p])$ext"
        $line = ($body -split "`n") | Where-Object { $_ -match "\s$([Regex]::Escape($needle))\s*$" } | Select-Object -First 1
        if (-not $line) {
            throw "conftest $Version checksums.txt did not contain entry for $needle (URL: $shaUrl)."
        }
        $hash = ($line -split '\s+')[0].ToLowerInvariant()
        if ($hash -notmatch '^[0-9a-f]{64}$') {
            throw "Parsed unexpected hash '$hash' for $needle."
        }
        $sha[$p] = $hash
        Write-Host ("    {0,-15} {1}" -f $p, $hash)
    }

    return [ordered]@{
        name            = 'conftest'
        version         = $Version
        urlTemplate     = 'https://github.com/open-policy-agent/conftest/releases/download/v{version}/conftest_{version}_{platform}{ext}'
        archive         = 'tar.gz'
        archives        = $archiveMap
        entrypoint      = 'conftest'
        platformAliases = $aliasMap
        sha256          = $sha
    }
}

# ----------------------------------------------------------------------
# mapotf: fetches 'checksums.txt' from the Azure/mapotf GitHub release.
# Asset filenames use the lock's default lowercase {os}_{arch} placeholders
# (mapotf_{version}_darwin_amd64.tar.gz), so no platformAliases map is
# needed - only a mixed archive map (.zip on Windows, .tar.gz elsewhere),
# the same shape as terraform-docs.
# ----------------------------------------------------------------------
function script:Get-MapotfEntry {
    param([Parameter(Mandatory)] [string] $Version)

    Write-Host "mapotf $Version" -ForegroundColor Cyan
    $shaUrl = "https://github.com/Azure/mapotf/releases/download/v$Version/checksums.txt"
    $body = script:Invoke-HttpGet -Url $shaUrl

    $archiveMap = [ordered]@{
        'windows-amd64' = 'zip'
        'windows-arm64' = 'zip'
        'linux-amd64'   = 'tar.gz'
        'linux-arm64'   = 'tar.gz'
        'darwin-amd64'  = 'tar.gz'
        'darwin-arm64'  = 'tar.gz'
    }
    $sha = [ordered]@{}
    foreach ($p in $script:platforms) {
        $ext = if ($archiveMap[$p] -eq 'zip') { '.zip' } else { '.tar.gz' }
        $osArch = $p -replace '-', '_'
        $needle = "mapotf_${Version}_$osArch$ext"
        $line = ($body -split "`n") | Where-Object { $_ -match "\s$([Regex]::Escape($needle))\s*$" } | Select-Object -First 1
        if (-not $line) {
            throw "mapotf $Version checksums.txt did not contain entry for $needle (URL: $shaUrl)."
        }
        $hash = ($line -split '\s+')[0].ToLowerInvariant()
        if ($hash -notmatch '^[0-9a-f]{64}$') {
            throw "Parsed unexpected hash '$hash' for $needle."
        }
        $sha[$p] = $hash
        Write-Host ("    {0,-15} {1}" -f $p, $hash)
    }

    return [ordered]@{
        name        = 'mapotf'
        version     = $Version
        urlTemplate = 'https://github.com/Azure/mapotf/releases/download/v{version}/mapotf_{version}_{os}_{arch}{ext}'
        archive     = 'tar.gz'
        archives    = $archiveMap
        entrypoint  = 'mapotf'
        sha256      = $sha
    }
}

# ----------------------------------------------------------------------
# Bicep: the project does not ship a checksums file, so download each
# per-platform binary and compute SHA256 locally. Files are kept in a
# temp dir and discarded after the loop.
# ----------------------------------------------------------------------
function script:Get-BicepEntry {
    param([Parameter(Mandatory)] [string] $Version)

    Write-Host "Bicep $Version" -ForegroundColor Cyan
    $aliases = [ordered]@{
        'windows-amd64' = 'win-x64.exe'
        'windows-arm64' = 'win-arm64.exe'
        'linux-amd64'   = 'linux-x64'
        'linux-arm64'   = 'linux-arm64'
        'darwin-amd64'  = 'osx-x64'
        'darwin-arm64'  = 'osx-arm64'
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-bicep-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $sha = [ordered]@{}
        foreach ($p in $script:platforms) {
            $asset = $aliases[$p]
            $url = "https://github.com/Azure/bicep/releases/download/v$Version/bicep-$asset"
            $dest = Join-Path $tempRoot "bicep-$asset"
            script:Save-Url -Url $url -Destination $dest
            $sha[$p] = script:Get-FileHashHex -Path $dest
            Write-Host ("    {0,-15} {1}" -f $p, $sha[$p])
        }

        return [ordered]@{
            name            = 'bicep'
            version         = $Version
            urlTemplate     = 'https://github.com/Azure/bicep/releases/download/v{version}/bicep-{platform}'
            archive         = 'raw'
            entrypoint      = 'bicep'
            platformAliases = $aliases
            sha256          = $sha
        }
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function script:Get-PolicyLibraryPin {
    param(
        [Parameter(Mandatory)] [string] $Ref,
        [Parameter(Mandatory)] $Existing
    )
    Write-Host "policy-library-avm $Ref" -ForegroundColor Cyan
    $version = $Ref.TrimStart('v')
    $url = ([string]$Existing.urlTemplate) `
        -replace '\{repository\}', ([string]$Existing.repository) `
        -replace '\{ref\}', $Ref `
        -replace '\{version\}', $version
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-policy-" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.tar.gz')
    try {
        Write-Host "  GET $url" -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing -MaximumRedirection 5
        $sha = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Host "  sha256 = $sha" -ForegroundColor DarkGray
        return [ordered]@{ ref = $Ref; sha256 = $sha }
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------
# Deterministic renderer for avm.pins.jsonc. The header comment block and
# everything from the policyLibrary banner onwards are preserved verbatim
# so hand-written JSONC documentation survives every refresh; only the
# schemaVersion + tools[] payload between them is regenerated.
# ----------------------------------------------------------------------
function script:Format-JsonString {
    param([AllowEmptyString()] [string] $Value)
    return (ConvertTo-Json -InputObject $Value -Compress)
}

function script:Format-JsonMap {
    param(
        [Parameter(Mandatory)] $Map,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [int] $Indent,
        [string[]] $Keys
    )
    if (-not $Keys) { $Keys = $script:platforms }
    $pad = ' ' * $Indent
    $inner = ' ' * ($Indent + 2)
    $lines = @("$pad$(script:Format-JsonString $Name): {")
    for ($i = 0; $i -lt $Keys.Count; $i++) {
        $comma = if ($i -lt $Keys.Count - 1) { ',' } else { '' }
        $lines += "$inner$(script:Format-JsonString $Keys[$i]): $(script:Format-JsonString $Map[$Keys[$i]])$comma"
    }
    $lines += "$pad}"
    return ($lines -join "`n")
}

function script:Format-JsonStringArray {
    param(
        [Parameter(Mandatory)] [string[]] $Items,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [int] $Indent
    )
    $pad = ' ' * $Indent
    $inner = ' ' * ($Indent + 2)
    $lines = @("$pad$(script:Format-JsonString $Name): [")
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $comma = if ($i -lt $Items.Count - 1) { ',' } else { '' }
        $lines += "$inner$(script:Format-JsonString $Items[$i])$comma"
    }
    $lines += "$pad]"
    return ($lines -join "`n")
}

function script:Format-ToolEntry {
    param(
        [Parameter(Mandatory)] $Tool,
        [Parameter(Mandatory)] [int] $Indent
    )
    $pad = ' ' * $Indent
    $padInner = ' ' * ($Indent + 2)

    $unsupported = @()
    if ($Tool.Contains('unsupportedPlatforms')) {
        $unsupported = @($Tool.unsupportedPlatforms)
    }
    $supportedPlatforms = $script:platforms | Where-Object { $unsupported -notcontains $_ }

    $blocks = New-Object System.Collections.Generic.List[string]
    foreach ($scalar in @('name', 'version', 'urlTemplate', 'archive', 'entrypoint')) {
        $blocks.Add("$padInner$(script:Format-JsonString $scalar): $(script:Format-JsonString ([string]$Tool[$scalar]))")
    }
    if ($Tool.Contains('platformAliases')) {
        $blocks.Add((script:Format-JsonMap -Map $Tool.platformAliases -Name 'platformAliases' -Indent ($Indent + 2) -Keys $supportedPlatforms))
    }
    if ($Tool.Contains('unsupportedPlatforms')) {
        $blocks.Add((script:Format-JsonStringArray -Items $unsupported -Name 'unsupportedPlatforms' -Indent ($Indent + 2)))
    }
    if ($Tool.Contains('archives')) {
        $blocks.Add((script:Format-JsonMap -Map $Tool.archives -Name 'archives' -Indent ($Indent + 2) -Keys $supportedPlatforms))
    }
    $blocks.Add((script:Format-JsonMap -Map $Tool.sha256 -Name 'sha256' -Indent ($Indent + 2) -Keys $supportedPlatforms))

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("$pad{")
    for ($i = 0; $i -lt $blocks.Count; $i++) {
        $comma = if ($i -lt $blocks.Count - 1) { ',' } else { '' }
        $lines.Add($blocks[$i] + $comma)
    }
    $lines.Add("$pad}")
    return ($lines -join "`n")
}

function script:Format-Pins {
    param(
        [Parameter(Mandatory)] [string] $Header,
        [Parameter(Mandatory)] [int] $SchemaVersion,
        [Parameter(Mandatory)] $Tools,
        [Parameter(Mandatory)] [string] $Tail
    )
    $body = New-Object System.Collections.Generic.List[string]
    $body.Add($Header.TrimEnd("`n"))
    $body.Add('  "schemaVersion": ' + $SchemaVersion + ',')
    $body.Add('')
    if ($Tools.Count -eq 0) {
        $body.Add('  "tools": [],')
    }
    else {
        $body.Add('  "tools": [')
        for ($i = 0; $i -lt $Tools.Count; $i++) {
            $comma = if ($i -lt $Tools.Count - 1) { ',' } else { '' }
            $body.Add((script:Format-ToolEntry -Tool $Tools[$i] -Indent 4) + $comma)
        }
        $body.Add('  ],')
    }
    $body.Add('')
    $body.Add($Tail.TrimEnd("`n"))
    return ($body -join "`n") + "`n"
}

# ----------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------

# Split the manifest into (header comments + '{'), the regenerated
# schemaVersion/tools payload, and the preserved policyLibrary/tflintPlugins
# tail. Both boundaries are anchored on structural markers so every JSONC
# comment outside the tools array survives a refresh untouched.
$existingText = ((Get-Content -LiteralPath $PinsPath -Raw) -replace "`r`n", "`n")
$existingLines = $existingText -split "`n"

$headerEnd = -1
$tailStart = -1
$toolsClose = -1
for ($i = 0; $i -lt $existingLines.Count; $i++) {
    if ($headerEnd -lt 0 -and $existingLines[$i] -match '^\s*"schemaVersion"\s*:') { $headerEnd = $i }
    if ($headerEnd -ge 0 -and $toolsClose -lt 0 -and $existingLines[$i] -match '^\s{2}\],\s*$') { $toolsClose = $i }
    if ($toolsClose -ge 0 -and $tailStart -lt 0 -and $existingLines[$i] -match '^\s*//\s*=+\s*$') { $tailStart = $i }
}
if ($headerEnd -lt 0) { throw "Could not find the '`"schemaVersion`"' key in $PinsPath." }
if ($tailStart -lt 0) { throw "Could not find the trailing section banner after the tools array in $PinsPath." }

$header = ($existingLines[0..($headerEnd - 1)] -join "`n")
$tail = ($existingLines[$tailStart..($existingLines.Count - 1)] -join "`n")

$existing = script:Read-PinsFile -Path $PinsPath
$schemaVersion = [int]$existing.schemaVersion
$toolList = @($existing.tools)

$newEntries = New-Object System.Collections.Generic.List[hashtable]
if ($Terraform) { $newEntries.Add((script:Get-TerraformEntry -Version $Terraform)) }
if ($Bicep) { $newEntries.Add((script:Get-BicepEntry -Version $Bicep)) }
if ($Tflint) { $newEntries.Add((script:Get-TflintEntry -Version $Tflint)) }
if ($TerraformDocs) { $newEntries.Add((script:Get-TerraformDocsEntry -Version $TerraformDocs)) }
if ($Conftest) { $newEntries.Add((script:Get-ConftestEntry -Version $Conftest)) }
if ($Mapotf) { $newEntries.Add((script:Get-MapotfEntry -Version $Mapotf)) }

# Merge: replace any existing entry with the same name, append otherwise.
$merged = New-Object System.Collections.Generic.List[hashtable]
foreach ($t in $toolList) {
    $name = [string]$t.name
    $replacement = $newEntries | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($replacement) {
        $merged.Add($replacement)
    }
    else {
        $merged.Add([hashtable]$t)
    }
}
foreach ($n in $newEntries) {
    if (-not ($merged | Where-Object { $_.name -eq $n.name })) {
        $merged.Add($n)
    }
}

# Sort tools alphabetically by name so diffs stay stable across refreshes.
$sorted = @($merged | Sort-Object { [string]$_.name })

if ($PolicyLibrary) {
    $policy = script:Get-PolicyLibraryPin -Ref $PolicyLibrary -Existing $existing.policyLibrary
    $tail = $tail `
        -replace '(?m)^(\s*"ref"\s*:\s*)"[^"]*"', ('${1}' + (script:Format-JsonString $policy.ref)) `
        -replace '(?m)^(\s*"sha256"\s*:\s*)"[^"]*"', ('${1}' + (script:Format-JsonString $policy.sha256))
}

foreach ($plugin in $TflintPlugin.Keys) {
    $version = [string]$TflintPlugin[$plugin]
    $pattern = '(?ms)("' + [regex]::Escape($plugin) + '"\s*:\s*)"[^"]*"(?=[^{}]*\}\s*\}?\s*$)'
    $tail = [regex]::Replace($tail, $pattern, { param($m) $m.Groups[1].Value + (script:Format-JsonString $version) })
}

$rendered = script:Format-Pins -Header $header -SchemaVersion $schemaVersion -Tools $sorted -Tail $tail

# Validate the new content by routing through the real Test-AvmPins
# in the Avm.Authoring module before touching the file on disk.
$validateTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-pins-validate-" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonc')
# Direct file write so validation runs even under -WhatIf.
[System.IO.File]::WriteAllText($validateTmp, $rendered, [System.Text.UTF8Encoding]::new($false))
try {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $parsed = script:Read-PinsFile -Path $validateTmp
    & (Get-Module Avm.Authoring) { param($L) Test-AvmPins -Pins $L | Out-Null } $parsed
    Write-Host 'Pin manifest validation: OK' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $validateTmp -Force -ErrorAction SilentlyContinue
}

if ($PSCmdlet.ShouldProcess($PinsPath, 'Write refreshed avm.pins.jsonc')) {
    # Use LF line endings and UTF-8 without a BOM to match repo convention.
    [System.IO.File]::WriteAllText($PinsPath, $rendered, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $PinsPath" -ForegroundColor Green
    Write-Host ("  Tools pinned: {0}" -f $sorted.Count)
    foreach ($t in $sorted) {
        Write-Host ("    - {0} {1}" -f $t.name, $t.version)
    }
}
else {
    Write-Host '(WhatIf) Pin manifest would be:' -ForegroundColor Yellow
    Write-Host $rendered
}
