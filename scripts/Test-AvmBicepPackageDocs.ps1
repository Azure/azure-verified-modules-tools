#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RegistryPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $RegistryCommit,

    [Parameter(Mandatory)]
    [string] $PackageRoot,

    [Parameter(Mandatory)]
    [string] $ModuleVersion
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ($env:AVM_OFFLINE -ne '1' -or $env:AVM_NO_AUTO_INSTALL -ne '1') {
    throw [System.InvalidOperationException]::new('Real package docs checks require both offline flags.')
}
$module = Import-Module -Name 'Avm.Authoring' -RequiredVersion $ModuleVersion -PassThru -ErrorAction Stop
if ($module.ModuleBase -cne $PackageRoot) {
    throw [System.InvalidOperationException]::new('Real docs did not import the extracted package by name.')
}
$registryRoot = (Resolve-Path -LiteralPath $RegistryPath).ProviderPath
$actualCommit = (& git -C $registryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -cne $RegistryCommit) {
    throw [System.InvalidOperationException]::new('Real docs require the recorded registry commit.')
}

$tool = & $module { Resolve-AvmTool -Name 'bicep' }
if ($tool.Version -cne '0.47.16') {
    throw [System.InvalidOperationException]::new('This qualification requires the previously verified Bicep 0.47.16.')
}
$banner = & $module { Invoke-AvmProcess -FilePath $args[0] -ArgumentList @('--version') } $tool.Path
if ($banner.StdOut -notlike '*0.47.16*') {
    throw [System.InvalidOperationException]::new('The cached compiler does not report the pinned version.')
}
$cache = Join-Path -Path $HOME -ChildPath '.bicep' `
    -AdditionalChildPath 'br', 'mcr.microsoft.com', 'bicep$avm$res$hybrid-compute$machine', '0.6.0$'
$cacheHashes = @(
    @{ File = 'manifest'; Hash = '1be3caa1aa3d48b799e798cd979c8cb7429bee3fd1fc86a7943a9576ea0cc75d' }
    @{ File = 'main.json'; Hash = 'cb411b4051a8e8005b6779185a37584ea09e237e56de0aa0ef8dda0d30de6f1a' }
    @{ File = 'source.tgz'; Hash = '0a44d22e3498b5cebb6399ee54d0a39f50cb6816617c8aabb01f6ab4bb698659' }
)
$dependencyProof = @(
    foreach ($entry in $cacheHashes) {
        $path = Join-Path $cache $entry.File
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne $entry.Hash) {
            throw [System.InvalidOperationException]::new("Previously verified dependency bytes changed: '$path'.")
        }
        [pscustomobject]@{ File = $path; Sha256 = $hash }
    }
)
$cacheMetadata = Get-Content -LiteralPath (Join-Path $cache 'metadata') -Raw | ConvertFrom-Json
if ($cacheMetadata.manifestDigest -cne ('sha256:' + $cacheHashes[0].Hash)) {
    throw [System.InvalidOperationException]::new('Published dependency cache metadata has a different manifest digest.')
}

$offlineInputs = @(
    foreach ($name in @('Get-AvmBicepApiSpecList', 'Get-AvmBicepMcrTagList')) {
        $rejected = $null
        try {
            $null = & $module {
                param($Name)
                if ($Name -eq 'Get-AvmBicepMcrTagList') {
                    & $Name -ModulePath 'avm/res/storage/storage-account'
                }
                else {
                    & $Name
                }
            } $name
        }
        catch {
            if ($_.Exception.GetType().Name -cne 'AvmConfigurationException' -or
                $_.Exception.Message -notlike 'AVM_OFFLINE=1:*') {
                throw
            }
            $rejected = [pscustomobject]@{
                Command = $name
                Status  = 'unavailable; explicitly rejected offline'
                Message = $_.Exception.Message
            }
        }
        if ($null -eq $rejected) {
            throw [System.InvalidOperationException]::new("$name incorrectly passed without its online input.")
        }
        $rejected
    }
)

$cases = @(
    @{ Name = 'HCI virtual-machine-instance'; Segments = @('avm', 'res', 'azure-stack-hci', 'virtual-machine-instance'); Expected = 1; Warnings = 0 }
    @{ Name = 'Vault root and children'; Segments = @('avm', 'res', 'key-vault', 'vault'); Expected = 4; Warnings = 1 }
    @{ Name = 'nested storage container and child'; Segments = @('avm', 'res', 'storage', 'storage-account', 'blob-service', 'container'); Expected = 2; Warnings = 0 }
)
$docsResults = @(
    foreach ($case in $cases) {
        $path = [System.IO.Path]::Combine([string[]](@($registryRoot) + $case.Segments))
        $before = @(
            Get-ChildItem -LiteralPath $path -Recurse -File |
                Where-Object { $_.Extension -ceq '.bicep' -or $_.Name -ceq 'README.md' } |
                ForEach-Object {
                    [pscustomobject]@{
                        Path  = $_.FullName
                        Hash  = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                        Ticks = $_.LastWriteTimeUtc.Ticks
                    }
                }
        )
        $result = Invoke-AvmDocs -Path $path -Ecosystem bicep -CheckDrift `
            -IncludeRenderedContent -SkipModuleVersionCheck
        if ($result.Status -ne 'pass' -or $result.FilesSelected -ne $case.Expected -or
            $result.FilesProcessed -ne $case.Expected -or @($result.NotRendered).Count -ne 0 -or
            @($result.Changed).Count -ne 0 -or @($result.Issues).Count -ne $case.Warnings -or
            @($result.GeneratedReadmes).Count -ne $case.Expected) {
            throw [System.InvalidOperationException]::new(
                "Real docs failed at $($case.Name): status=$($result.Status), " +
                "selected=$($result.FilesSelected), rendered=$($result.FilesProcessed), expected=$($case.Expected), " +
                "issues=$($result.Issues | ConvertTo-Json -Compress -Depth 6)")
        }
        foreach ($issue in $result.Issues) {
            if ($issue.Severity -cne 'warning' -or $issue.Code -cne 'avm.bicep.docs-example-comments' -or
                $issue.File -cne 'README.md' -or $issue.Message -notlike '*only by 8 generated JSON-example grouping comments*') {
                throw [System.InvalidOperationException]::new('An unexpected real-docs warning cannot qualify.')
            }
        }
        $readmes = @(
            foreach ($generated in $result.GeneratedReadmes) {
                $readmePath = Join-Path $path $generated.Path
                $trackedHash = (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash.ToLowerInvariant()
                $bytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($generated.Content)
                $generatedHash = [System.Convert]::ToHexString(
                    [System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                $exact = $trackedHash -ceq $generatedHash
                if (-not $exact -and ($case.Name -cne 'Vault root and children' -or
                        $generated.Path -cne 'README.md' -or
                        $trackedHash -cne '72befb145543d707ba849143eccb8d4b17efe2b09385156e6a5cc1b7060d8e01' -or
                        $generatedHash -cne 'de837feee2890a3bab192282fb19f5d8fb80a8d7d2315bbf85bf425220890066')) {
                    throw [System.InvalidOperationException]::new("Unqualified README bytes at '$readmePath'.")
                }
                [pscustomobject]@{
                    Path            = [System.IO.Path]::GetRelativePath($registryRoot, $readmePath).Replace('\', '/')
                    ByteExact       = $exact
                    TrackedSha256   = $trackedHash
                    GeneratedSha256 = $generatedHash
                }
            }
        )
        foreach ($file in $before) {
            if ((Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash -cne $file.Hash -or
                (Get-Item -LiteralPath $file.Path).LastWriteTimeUtc.Ticks -ne $file.Ticks) {
                throw [System.InvalidOperationException]::new("Docs changed source/README bytes or timestamps: '$($file.Path)'.")
            }
        }
        [pscustomobject]@{
            Scope          = $case.Name
            Status         = $result.Status
            Selected       = $result.FilesSelected
            Rendered       = $result.FilesProcessed
            Issues         = @($result.Issues)
            Readmes        = $readmes
            UnchangedFiles = $before.Count
        }
    }
)
$status = @(& git -C $registryRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) {
    throw [System.InvalidOperationException]::new('Real docs changed the pinned registry snapshot.')
}
[pscustomobject]@{
    Kind            = 'real pinned compiler/render checks; unmodified registry sources and verified published cache, no aliases'
    RegistryCommit  = $actualCommit
    CompilerPath    = $tool.Path
    CompilerVersion = $tool.Version
    CompilerBanner  = $banner.StdOut.Trim()
    Dependency      = $dependencyProof
    OfflineInputs   = $offlineInputs
    Scopes          = $docsResults
    RegistryClean   = $true
    Offline         = $true
}
