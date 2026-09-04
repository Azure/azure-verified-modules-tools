#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
    $script:avmDocsRoot = Join-Path $script:repoRoot 'scripts' 'avm-docs'
    . (Join-Path $script:avmDocsRoot 'AvmDocs.Common.ps1')
}

Describe 'AVM docs parity scripts' {
    It 'parses each PowerShell entry point without errors' {
        $scriptPaths = @(
            (Join-Path $script:avmDocsRoot 'AvmDocs.Common.ps1')
            (Join-Path $script:avmDocsRoot 'Test-AvmDocsParity.ps1')
            (Join-Path $script:avmDocsRoot 'Invoke-AllAvmDocsParity.ps1')
        )

        foreach ($scriptPath in $scriptPaths) {
            $tokens = $null
            $errors = $null
            [void] [Management.Automation.Language.Parser]::ParseFile(
                $scriptPath,
                [ref] $tokens,
                [ref] $errors)
            @($errors).Count | Should -Be 0 -Because "$scriptPath must parse"
        }
    }

    It 'uses only invocation custom-value options for template inputs' {
        $scriptText = Get-Content -LiteralPath (Join-Path $script:avmDocsRoot 'Test-AvmDocsParity.ps1') -Raw

        $scriptText | Should -Not -Match '--template-file'
        $scriptText | Should -Not -Match '--template-root'
        $scriptText | Should -Match '--custom-template-value-file-path'
        $scriptText | Should -Match '--custom-template-value'
    }

    It 'uses one lock path for Windows path case variants' -Skip:(-not $IsWindows) {
        $repositoryPath = (Join-Path $TestDrive 'case-repository')

        Get-AvmDocsConfigurationLockPath -RepositoryPath $repositoryPath |
            Should -Be (Get-AvmDocsConfigurationLockPath -RepositoryPath $repositoryPath.ToUpperInvariant())
    }

    It 'merges one immutable renderer configuration and restores the original file' {
        $repositoryPath = Join-Path $TestDrive 'repository'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        $configPath = Join-Path $repositoryPath 'bicepconfig.json'
        $original = @'
// existing settings must survive the temporary merge
{
  "extensions": {
    "example": "br:example"
  }
}
'@
        [IO.File]::WriteAllText($configPath, $original, [Text.UTF8Encoding]::new($false))
        $originalBytes = [IO.File]::ReadAllBytes($configPath)

        $context = New-AvmDocsConfigurationContext `
            -RepositoryPath $repositoryPath `
            -ReadmeTemplatePath (Join-Path $script:avmDocsRoot 'README.byte-parity.scriban') `
            -ModelIndexTemplatePath (Join-Path $script:avmDocsRoot 'model-index.scriban')
        try {
            $configuration = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable

            $configuration.extensions.example | Should -Be 'br:example'
            $configuration.documentation.template.file | Should -Be (Join-Path $context.RendererRoot 'render.scriban')
            $configuration.documentation.template.includeRoot | Should -Be $context.RendererRoot
            $configuration.documentation.template.ContainsKey('values') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $context.RendererRoot 'README.scriban') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $context.RendererRoot 'model-index.scriban') | Should -BeTrue
        } finally {
            Remove-AvmDocsConfigurationContext -Context $context
        }

        [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            [IO.File]::ReadAllBytes($configPath),
            $originalBytes) | Should -BeTrue
        Test-Path -LiteralPath $context.LockPath | Should -BeTrue
        $releasedLock = [IO.File]::Open(
            $context.LockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None)
        $releasedLock.Dispose()
        Remove-Item -LiteralPath $context.LockPath -Force
        Test-Path -LiteralPath $context.RendererRoot | Should -BeFalse
    }

    It 'snapshots the configuration only after acquiring the exclusive lock' {
        $repositoryPath = Join-Path $TestDrive 'concurrent-repository'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        $configPath = Join-Path $repositoryPath 'bicepconfig.json'
        $firstConfig = '{ "analyzers": { "core": { "enabled": true } } }'
        $secondConfig = '{ "analyzers": { "core": { "enabled": false } } }'
        [IO.File]::WriteAllText($configPath, $firstConfig, [Text.UTF8Encoding]::new($false))
        $lockPath = Get-AvmDocsConfigurationLockPath -RepositoryPath (Resolve-Path $repositoryPath).Path
        $lockStream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None)
        $job = Start-Job -ScriptBlock {
            param ($CommonPath, $RepositoryPath, $ReadmeTemplatePath, $ModelIndexTemplatePath)

            . $CommonPath
            $context = New-AvmDocsConfigurationContext `
                -RepositoryPath $RepositoryPath `
                -ReadmeTemplatePath $ReadmeTemplatePath `
                -ModelIndexTemplatePath $ModelIndexTemplatePath
            Remove-AvmDocsConfigurationContext -Context $context
        } -ArgumentList @(
            (Join-Path $script:avmDocsRoot 'AvmDocs.Common.ps1'),
            $repositoryPath,
            (Join-Path $script:avmDocsRoot 'README.byte-parity.scriban'),
            (Join-Path $script:avmDocsRoot 'model-index.scriban')
        )

        try {
            Start-Sleep -Milliseconds 500
            $job.State | Should -Be 'Running'
            [IO.File]::WriteAllText($configPath, $secondConfig, [Text.UTF8Encoding]::new($false))
        } finally {
            $lockStream.Dispose()
        }

        try {
            $job | Wait-Job -Timeout 30 | Should -Not -BeNullOrEmpty
            $job.State | Should -Be 'Completed'
            Receive-Job -Job $job -ErrorAction Stop
            [IO.File]::ReadAllText($configPath) | Should -Be $secondConfig
        } finally {
            Remove-Job -Job $job -Force
            Remove-Item -LiteralPath $lockPath -Force
        }
    }

    It 'does not truncate the destination when the atomic commit fails' {
        $configPath = Join-Path $TestDrive 'atomic-config.json'
        $originalBytes = [Text.Encoding]::UTF8.GetBytes('{ "original": true }')
        [IO.File]::WriteAllBytes($configPath, $originalBytes)
        Mock Move-AvmDocsFile { throw 'simulated atomic commit failure' }

        {
            Set-AvmDocsFileBytesAtomically `
                -Path $configPath `
                -Content ([Text.Encoding]::UTF8.GetBytes('{ "replacement": true }'))
        } | Should -Throw '*simulated atomic commit failure*'

        [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            [IO.File]::ReadAllBytes($configPath),
            $originalBytes) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'atomic-config.json.*.tmp').Count | Should -Be 0
    }
}
