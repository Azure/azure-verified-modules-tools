<#
.SYNOPSIS
    Refresh src/Avm.Authoring/Resources/tools.lock.psd1 with verified
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
      - bicep         : downloads each of the six per-platform binaries from
                        https://github.com/Azure/bicep/releases/download/v<v>/.
                        Each binary is ~10-20 MB, so the whole pass needs
                        ~80-120 MB of network. Cancellable.

    The script never publishes anything; it only mutates a single .psd1
    file under source control. The resulting lock is then validated via
    Test-AvmToolsLock by importing the Avm.Authoring module.

.PARAMETER Terraform
    Terraform version to lock, e.g. '1.9.5'. Skip the terraform tool when
    omitted.

.PARAMETER Bicep
    Bicep version to lock, e.g. '0.30.3' (no leading 'v'). Skip the bicep
    tool when omitted.

.PARAMETER Tflint
    Tflint version to lock, e.g. '0.55.1' (no leading 'v'). Skip the tflint
    tool when omitted.

.PARAMETER TerraformDocs
    terraform-docs version to lock, e.g. '0.20.0' (no leading 'v'). Skip
    the terraform-docs tool when omitted.

.PARAMETER Conftest
    conftest version to lock, e.g. '0.68.2' (no leading 'v'). Skip the
    conftest tool when omitted.

.PARAMETER LockPath
    Override the path to tools.lock.psd1. Defaults to the in-tree copy
    under src/Avm.Authoring/Resources/.

.PARAMETER WhatIf
    Show what would change without writing the file.

.EXAMPLE
    ./scripts/Update-AvmToolsLock.ps1 -Terraform 1.9.5 -Bicep 0.30.3

.EXAMPLE
    ./scripts/Update-AvmToolsLock.ps1 -Terraform 1.9.8

.EXAMPLE
    ./scripts/Update-AvmToolsLock.ps1 -Conftest 0.68.2

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
    [string] $LockPath = (Join-Path $PSScriptRoot '..' 'src' 'Avm.Authoring' 'Resources' 'tools.lock.psd1')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $Terraform -and -not $Bicep -and -not $Tflint -and -not $TerraformDocs -and -not $Conftest) {
    throw "Specify at least one of -Terraform <version>, -Bicep <version>, -Tflint <version>, -TerraformDocs <version>, or -Conftest <version>."
}

$LockPath = (Resolve-Path -LiteralPath $LockPath).Path
Write-Host "Lock file: $LockPath" -ForegroundColor Cyan

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

# ----------------------------------------------------------------------
# Deterministic renderer for tools.lock.psd1. We emit a fixed header
# (preserved verbatim from the existing file's leading comment block)
# followed by the @{...} payload in a stable key order.
# ----------------------------------------------------------------------
function script:Format-StringValue {
    param([string] $Value)
    # Single-quoted with embedded single quotes doubled.
    return "'" + ($Value -replace "'", "''") + "'"
}

function script:Format-PlatformHashBlock {
    param(
        [Parameter(Mandatory)] $Map,
        [Parameter(Mandatory)] [int] $OuterIndent,
        [string[]] $Keys
    )
    # Renders:
    #     @{
    #         'windows-amd64' = '...'
    #         ...
    #     }
    # where 'OuterIndent' is the column of the opening '@{'. Pads every
    # key to the longest quoted key width so PSAlignAssignmentStatement
    # is satisfied. -Keys lets the caller render a subset of platforms
    # (e.g. for tools that omit windows-arm64).
    if (-not $Keys) { $Keys = $script:platforms }
    $outer = ' ' * $OuterIndent
    $inner = ' ' * ($OuterIndent + 4)
    $quotedKeys = $Keys | ForEach-Object { "'$_'" }
    $keyWidth = ($quotedKeys | Measure-Object -Property Length -Maximum).Maximum
    $lines = @('@{')
    foreach ($p in $Keys) {
        $quoted = "'$p'"
        $lines += "$inner" + $quoted.PadRight($keyWidth) + ' = ' + (script:Format-StringValue $Map[$p])
    }
    $lines += "$outer}"
    return ($lines -join "`n")
}

function script:Format-PlatformStringArray {
    param(
        [Parameter(Mandatory)] [string[]] $Items,
        [Parameter(Mandatory)] [int] $OuterIndent
    )
    # Renders:
    #     @(
    #         'windows-arm64'
    #     )
    $outer = ' ' * $OuterIndent
    $inner = ' ' * ($OuterIndent + 4)
    $lines = @('@(')
    foreach ($v in $Items) {
        $lines += "$inner" + (script:Format-StringValue $v)
    }
    $lines += "$outer)"
    return ($lines -join "`n")
}

function script:Format-ToolEntry {
    param(
        [Parameter(Mandatory)] $Tool,
        [Parameter(Mandatory)] [int] $Indent
    )
    $pad = ' ' * $Indent
    $padInner = ' ' * ($Indent + 4)
    # Compute the alignment column from the longest key actually present.
    $keys = @('name', 'version', 'urlTemplate', 'archive', 'entrypoint')
    if ($Tool.Contains('platformAliases')) { $keys += 'platformAliases' }
    if ($Tool.Contains('unsupportedPlatforms')) { $keys += 'unsupportedPlatforms' }
    if ($Tool.Contains('archives')) { $keys += 'archives' }
    $keys += 'sha256'
    $keyWidth = ($keys | Measure-Object -Property Length -Maximum).Maximum

    $unsupported = @()
    if ($Tool.Contains('unsupportedPlatforms')) {
        $unsupported = @($Tool.unsupportedPlatforms)
    }
    $supportedPlatforms = $script:platforms | Where-Object { $unsupported -notcontains $_ }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("$pad@{")
    $lines.Add("$padInner" + 'name'.PadRight($keyWidth) + ' = ' + (script:Format-StringValue $Tool.name))
    $lines.Add("$padInner" + 'version'.PadRight($keyWidth) + ' = ' + (script:Format-StringValue $Tool.version))
    $lines.Add("$padInner" + 'urlTemplate'.PadRight($keyWidth) + ' = ' + (script:Format-StringValue $Tool.urlTemplate))
    $lines.Add("$padInner" + 'archive'.PadRight($keyWidth) + ' = ' + (script:Format-StringValue $Tool.archive))
    $lines.Add("$padInner" + 'entrypoint'.PadRight($keyWidth) + ' = ' + (script:Format-StringValue $Tool.entrypoint))
    if ($Tool.Contains('platformAliases')) {
        $aliasBlock = script:Format-PlatformHashBlock -Map $Tool.platformAliases -OuterIndent ($Indent + 4) -Keys $supportedPlatforms
        $lines.Add("$padInner" + 'platformAliases'.PadRight($keyWidth) + ' = ' + $aliasBlock)
    }
    if ($Tool.Contains('unsupportedPlatforms')) {
        $unsupportedBlock = script:Format-PlatformStringArray -Items $unsupported -OuterIndent ($Indent + 4)
        $lines.Add("$padInner" + 'unsupportedPlatforms'.PadRight($keyWidth) + ' = ' + $unsupportedBlock)
    }
    if ($Tool.Contains('archives')) {
        $archivesBlock = script:Format-PlatformHashBlock -Map $Tool.archives -OuterIndent ($Indent + 4) -Keys $supportedPlatforms
        $lines.Add("$padInner" + 'archives'.PadRight($keyWidth) + ' = ' + $archivesBlock)
    }
    $shaBlock = script:Format-PlatformHashBlock -Map $Tool.sha256 -OuterIndent ($Indent + 4) -Keys $supportedPlatforms
    $lines.Add("$padInner" + 'sha256'.PadRight($keyWidth) + ' = ' + $shaBlock)
    $lines.Add("$pad}")
    return ($lines -join "`n")
}

function script:Format-Lock {
    param(
        [Parameter(Mandatory)] [string] $Header,
        [Parameter(Mandatory)] [int] $SchemaVersion,
        [Parameter(Mandatory)] $Tools
    )
    $body = New-Object System.Collections.Generic.List[string]
    $body.Add($Header.TrimEnd())
    $body.Add('@{')
    $body.Add('    schemaVersion = ' + $SchemaVersion)
    if ($Tools.Count -eq 0) {
        $body.Add('    tools         = @()')
    }
    else {
        $body.Add('    tools         = @(')
        for ($i = 0; $i -lt $Tools.Count; $i++) {
            $entry = script:Format-ToolEntry -Tool $Tools[$i] -Indent 8
            $body.Add($entry)
        }
        $body.Add('    )')
    }
    $body.Add('}')
    return ($body -join "`n") + "`n"
}

# ----------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------

# Extract the leading comment block (everything before the first @{ at
# column 0) so we preserve the schema documentation.
$existingText = Get-Content -LiteralPath $LockPath -Raw
$openIdx = $existingText.IndexOf("`n@{")
if ($openIdx -lt 0) {
    throw "Could not find '@{' opening brace in $LockPath."
}
$header = $existingText.Substring(0, $openIdx)

$existing = Import-PowerShellDataFile -LiteralPath $LockPath
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
        $merged.Add($t)
    }
}
foreach ($n in $newEntries) {
    if (-not ($merged | Where-Object { $_.name -eq $n.name })) {
        $merged.Add($n)
    }
}

# Sort tools alphabetically by name so diffs stay stable across refreshes.
$sorted = @($merged | Sort-Object { [string]$_.name })

$rendered = script:Format-Lock -Header $header -SchemaVersion $schemaVersion -Tools $sorted

# Validate the new content by routing through the real Test-AvmToolsLock
# in the Avm.Authoring module before touching the file on disk.
$validateTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-lock-validate-" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.psd1')
# Direct file write so validation runs even under -WhatIf.
[System.IO.File]::WriteAllText($validateTmp, ($rendered -replace "`r`n", "`n"))
try {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $parsed = Import-PowerShellDataFile -LiteralPath $validateTmp
    & (Get-Module Avm.Authoring) { param($L) Test-AvmToolsLock -Lock $L | Out-Null } $parsed
    Write-Host 'Lock validation: OK' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $validateTmp -Force -ErrorAction SilentlyContinue
}

if ($PSCmdlet.ShouldProcess($LockPath, 'Write refreshed tools.lock.psd1')) {
    # Use LF line endings to match repo convention.
    [System.IO.File]::WriteAllText($LockPath, ($rendered -replace "`r`n", "`n"))
    Write-Host "Wrote $LockPath" -ForegroundColor Green
    Write-Host ("  Tools in lock: {0}" -f $sorted.Count)
    foreach ($t in $sorted) {
        Write-Host ("    - {0} {1}" -f $t.name, $t.version)
    }
}
else {
    Write-Host '(WhatIf) Lock file would be:' -ForegroundColor Yellow
    Write-Host $rendered
}
