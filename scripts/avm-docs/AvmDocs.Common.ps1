function Write-AvmDocsText {
    param (
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content
    )

    [IO.File]::WriteAllText($Path, $Content.ReplaceLineEndings("`n"), [Text.UTF8Encoding]::new($false))
}

function Set-AvmDocsFileBytesAtomically {
    param (
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [byte[]] $Content
    )

    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $stream = [IO.File]::Open(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        try {
            $stream.Write($Content)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }

        Move-AvmDocsFile -SourcePath $temporaryPath -DestinationPath $Path
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Move-AvmDocsFile {
    param (
        [Parameter(Mandatory)]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [string] $DestinationPath
    )

    [IO.File]::Move($SourcePath, $DestinationPath, $true)
}

function Get-AvmDocsConfigurationLockPath {
    param (
        [Parameter(Mandatory)]
        [string] $RepositoryPath
    )

    $lockKey = if ([OperatingSystem]::IsWindows()) {
        $RepositoryPath.ToUpperInvariant()
    } else {
        $RepositoryPath
    }
    $repositoryPathHash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($lockKey))).ToLowerInvariant()
    return Join-Path ([IO.Path]::GetTempPath()) "avm-docs-$repositoryPathHash.lock"
}

function Enter-AvmDocsConfigurationLock {
    param (
        [Parameter(Mandatory)]
        [string] $LockPath
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed -lt [TimeSpan]::FromMinutes(5)) {
        try {
            return [IO.File]::Open(
                $LockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None)
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }

    throw "Timed out waiting for the AVM docs configuration lock [$LockPath]."
}

function New-AvmDocsConfigurationContext {
    param (
        [Parameter(Mandatory)]
        [string] $RepositoryPath,

        [Parameter(Mandatory)]
        [string] $ReadmeTemplatePath,

        [Parameter(Mandatory)]
        [string] $ModelIndexTemplatePath
    )

    $resolvedRepositoryPath = (Resolve-Path -LiteralPath $RepositoryPath).Path
    $configPath = Join-Path $resolvedRepositoryPath 'bicepconfig.json'
    $lockPath = Get-AvmDocsConfigurationLockPath -RepositoryPath $resolvedRepositoryPath
    $rendererRoot = Join-Path ([IO.Path]::GetTempPath()) "avm-docs-render-$([Guid]::NewGuid().ToString('N'))"
    $lockStream = $null
    $configWritten = $false
    $originalConfigExists = $false
    $originalConfigBytes = $null

    try {
        $lockStream = Enter-AvmDocsConfigurationLock -LockPath $lockPath

        $originalConfigExists = Test-Path -LiteralPath $configPath
        $originalConfigBytes = if ($originalConfigExists) {
            [IO.File]::ReadAllBytes($configPath)
        } else {
            $null
        }
        $configuration = if ($originalConfigExists) {
            Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
        } else {
            [ordered]@{}
        }
        $documentation = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'bicepconfig.json') -Raw |
                ConvertFrom-Json -AsHashtable).documentation

        New-Item -ItemType Directory -Path $rendererRoot -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'render.scriban') -Destination $rendererRoot
        Copy-Item -LiteralPath $ReadmeTemplatePath -Destination (Join-Path $rendererRoot 'README.scriban')
        Copy-Item -LiteralPath $ModelIndexTemplatePath -Destination (Join-Path $rendererRoot 'model-index.scriban')

        $documentation.template = [ordered]@{
            file        = (Join-Path $rendererRoot 'render.scriban')
            includeRoot = $rendererRoot
        }
        $configuration.documentation = $documentation
        $configBytes = [Text.UTF8Encoding]::new($false).GetBytes(
            ($configuration | ConvertTo-Json -Depth 100).ReplaceLineEndings("`n"))
        Set-AvmDocsFileBytesAtomically -Path $configPath -Content $configBytes
        $configWritten = $true

        return [pscustomobject]@{
            ConfigPath = $configPath
            LockPath = $lockPath
            LockStream = $lockStream
            OriginalConfigExists = $originalConfigExists
            OriginalConfigBytes = $originalConfigBytes
            RendererRoot = $rendererRoot
        }
    } catch {
        if ($configWritten) {
            if ($originalConfigExists) {
                Set-AvmDocsFileBytesAtomically -Path $configPath -Content $originalConfigBytes
            } else {
                Remove-Item -LiteralPath $configPath -Force
            }
        }
        if (Test-Path -LiteralPath $rendererRoot) {
            Remove-Item -LiteralPath $rendererRoot -Recurse -Force
        }
        if ($null -ne $lockStream) {
            $lockStream.Dispose()
        }
        throw
    }
}

function Remove-AvmDocsConfigurationContext {
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    try {
        if ($Context.OriginalConfigExists) {
            Set-AvmDocsFileBytesAtomically -Path $Context.ConfigPath -Content $Context.OriginalConfigBytes
        } else {
            Remove-Item -LiteralPath $Context.ConfigPath -Force
        }
        if (Test-Path -LiteralPath $Context.RendererRoot) {
            Remove-Item -LiteralPath $Context.RendererRoot -Recurse -Force
        }
    } finally {
        $Context.LockStream.Dispose()
    }
}
