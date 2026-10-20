function Get-AvmBicepDocsRenderInput {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [pscustomobject] $Configuration,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.Dictionary[string, string]] $Stages
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $Configuration.UsesPackageTemplate) {
        return [pscustomobject]@{
            SourcePath       = $SourcePath
            WorkingDirectory = [System.IO.Path]::GetDirectoryName($SourcePath)
        }
    }

    $sourceRoot = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Root))
    if ($Configuration.ConfigPath) {
        $relativeConfig = [System.IO.Path]::GetRelativePath($sourceRoot, $Configuration.ConfigPath)
        if ($relativeConfig -eq '..' -or
            $relativeConfig.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal)) {
            $sourceRoot = [System.IO.Path]::GetDirectoryName($Configuration.ConfigPath)
        }
    }
    if ($null -eq [System.IO.Directory]::GetParent($sourceRoot) -or
        $sourceRoot -eq [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) {
        throw [AvmConfigurationException]::new(
            "Bicep documentation needs a repository-scoped configuration directory, not '$sourceRoot'.")
    }

    $stage = ''
    if (-not $Stages.TryGetValue($sourceRoot, [ref]$stage)) {
        $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-bicep-docs-' + [guid]::NewGuid().ToString('N'))
        $relativeStage = [System.IO.Path]::GetRelativePath($sourceRoot, $stage)
        if (-not [System.IO.Path]::IsPathRooted($relativeStage) -and
            -not $relativeStage.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal)) {
            throw [AvmConfigurationException]::new(
                'Bicep documentation staging must be outside the source tree.')
        }
        if (-not $PSCmdlet.ShouldProcess($stage, 'Stage read-only Bicep documentation inputs')) {
            throw [AvmConfigurationException]::new('Bicep documentation staging was not approved.')
        }
        $null = [System.IO.Directory]::CreateDirectory($stage)
        $copied = $false
        try {
            if (-not $IsWindows) {
                [System.IO.File]::SetUnixFileMode($stage,
                    [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute)
            }
            $pending = [System.Collections.Generic.Stack[string]]::new()
            $pending.Push($sourceRoot)
            while ($pending.Count -gt 0) {
                $directory = $pending.Pop()
                $directoryItem = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
                if ($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    throw [AvmConfigurationException]::new(
                        "Bicep documentation cannot stage a linked source directory: $directory")
                }
                foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
                    if ($item.Name -eq '.git') { continue }
                    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        throw [AvmConfigurationException]::new(
                            "Bicep documentation cannot stage a linked source entry: $($item.FullName)")
                    }
                    $relative = [System.IO.Path]::GetRelativePath($sourceRoot, $item.FullName)
                    $destination = Resolve-AvmArchiveEntryPath -TargetDir $stage -EntryName $relative
                    if ($item.PSIsContainer) {
                        $null = [System.IO.Directory]::CreateDirectory($destination)
                        $pending.Push($item.FullName)
                    }
                    else {
                        [System.IO.File]::Copy($item.FullName, $destination)
                        if ($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                            [System.IO.File]::SetAttributes(
                                $destination, ([System.IO.File]::GetAttributes($destination) -band
                                    (-bnot [System.IO.FileAttributes]::ReadOnly)))
                        }
                    }
                }
            }
            $Stages.Add($sourceRoot, $stage)
            $copied = $true
        }
        finally {
            if (-not $copied) {
                [System.IO.Directory]::Delete($stage, $true)
            }
        }
    }

    $configPath = if ($Configuration.ConfigPath) {
        Resolve-AvmArchiveEntryPath -TargetDir $stage -EntryName (
            [System.IO.Path]::GetRelativePath($sourceRoot, $Configuration.ConfigPath))
    }
    else { Join-Path $stage 'bicepconfig.json' }
    $config = [System.Text.Json.Nodes.JsonObject]::new()
    if ($Configuration.ConfigPath) {
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.AllowTrailingCommas = $true
        $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Skip
        $config = [System.Text.Json.Nodes.JsonNode]::Parse(
            [System.IO.File]::ReadAllText($Configuration.ConfigPath), $null, $options)
    }
    if (-not $config.ContainsKey('documentation')) {
        $config['documentation'] = [System.Text.Json.Nodes.JsonObject]::new()
    }
    $config['documentation']['template'] = [System.Text.Json.Nodes.JsonObject]::new()
    $config['documentation']['template']['file'] = [System.Text.Json.Nodes.JsonValue]::Create(
        [string]$Configuration.TemplatePath)
    [System.IO.File]::WriteAllText(
        $configPath, $config.ToJsonString(),
        [System.Text.UTF8Encoding]::new($false, $true))
    $stagedSource = Resolve-AvmArchiveEntryPath -TargetDir $stage -EntryName (
        [System.IO.Path]::GetRelativePath($sourceRoot, $SourcePath))
    return [pscustomobject]@{
        SourcePath       = $stagedSource
        WorkingDirectory = [System.IO.Path]::GetDirectoryName($stagedSource)
    }
}
