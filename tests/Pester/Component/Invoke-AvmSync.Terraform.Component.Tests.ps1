#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Component-tier coverage for the managed-files sync verb
# (Invoke-AvmSync -> Get-AvmModuleContext -> Sync-AvmManagedFile).
# Exercises the public verb end-to-end against a real on-disk fixture:
# a Terraform module working tree plus a local governance source
# (-ManagedFilesLocalPath), with no cmdlet-level mocks. Because the
# managed-files engine copies files and shells out to plain git (never
# an AVM-pinned tool), there is no stub launcher / PATH shim to install
# here - the offline local-source path is fully deterministic.

# Windows 8.3 short components survive Resolve-Path but are expanded by
# Get-ChildItem. Only a filesystem that produces that length delta can
# reproduce the relative-key regression guarded below.
BeforeDiscovery {
    $tempRoot = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $script:NoShortPathDelta = ((Resolve-Path -LiteralPath $tempRoot).Path.Length -eq (Get-Item -LiteralPath $tempRoot -Force).FullName.Length)
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    Import-Module -Name $script:moduleManifest -Force

    # Builds a self-contained fixture: a terraform module working tree plus a
    # local governance base folder (root/ overlay), returned as a pair so each
    # It can mutate its own copy without cross-contamination.
    function script:New-SyncFixture {
        param([string] $Name)

        $moduleDir = Join-Path $TestDrive ("terraform-azurerm-avm-res-$Name")
        $null = New-Item -ItemType Directory -Path $moduleDir -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $moduleDir 'tests') -Force
        $mainTf = @(
            '# AVM managed-files sync fixture module',
            'terraform {',
            '  required_version = ">= 1.0"',
            '}'
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $moduleDir 'main.tf') -Value $mainTf -Encoding utf8NoBOM

        $base = Join-Path $TestDrive ("gov-$Name")
        $root = Join-Path $base 'root'
        $null = New-Item -ItemType Directory -Path $root -Force
        Set-Content -LiteralPath (Join-Path $root '.gitignore') -Value "*.tfstate`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $root 'SECURITY.md') -Value "# Security`n" -NoNewline

        [pscustomobject]@{ ModuleDir = $moduleDir; Base = $base; Root = $root }
    }
}

AfterAll {
    Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Invoke-AvmSync (terraform managed-files sync end-to-end)' -Tag 'Component' {

    It 'reconciles the working tree against a local governance source and writes the managed files' {
        $fx = script:New-SyncFixture -Name 'apply'

        $result = Invoke-AvmSync -Path $fx.ModuleDir -Ecosystem terraform -ManagedFilesLocalPath $fx.Base

        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['Engine'].Value         | Should -Be 'terraform'
        $result.PSObject.Properties['Tool'].Value           | Should -Be 'managed-files'
        $result.PSObject.Properties['ToolSource'].Value      | Should -Be 'local'
        $result.PSObject.Properties['Status'].Value          | Should -Be 'pass'
        $result.PSObject.Properties['FilesProcessed'].Value  | Should -Be 2
        @($result.PSObject.Properties['Added'].Value).Count  | Should -Be 2
        @($result.PSObject.Properties['Issues'].Value).Count | Should -Be 0

        Test-Path (Join-Path $fx.ModuleDir '.gitignore')  | Should -BeTrue
        Test-Path (Join-Path $fx.ModuleDir 'SECURITY.md') | Should -BeTrue
    }

    It 'reports drift as a failing status without writing when -CheckDrift is set' {
        $fx = script:New-SyncFixture -Name 'drift'

        # First apply brings the working tree in sync.
        Invoke-AvmSync -Path $fx.ModuleDir -Ecosystem terraform -ManagedFilesLocalPath $fx.Base | Out-Null

        # Mutate the governance source so the on-disk copy is now stale.
        Set-Content -LiteralPath (Join-Path $fx.Root '.gitignore') -Value "*.tfstate`n.terraform/`n" -NoNewline

        $result = Invoke-AvmSync -Path $fx.ModuleDir -Ecosystem terraform -ManagedFilesLocalPath $fx.Base -CheckDrift

        $result.PSObject.Properties['Status'].Value          | Should -Be 'fail'
        @($result.PSObject.Properties['Updated'].Value).Count | Should -Be 1
        @($result.PSObject.Properties['Issues'].Value).Count  | Should -BeGreaterThan 0

        # Report-only: the on-disk copy is untouched (still the pre-drift content).
        $onDisk = Get-Content -Raw -LiteralPath (Join-Path $fx.ModuleDir '.gitignore')
        $onDisk | Should -Not -Match 'terraform'
    }

    It 'resolves managed-file relative paths from the enumerated children, not from string arithmetic' -Skip:$script:NoShortPathDelta {
        $tempRoot = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        $probe = Join-Path $tempRoot ('avm-sync-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $probe -Force
        try {
            $moduleDir = Join-Path $probe 'terraform-azurerm-avm-res-shortpath'
            $root = Join-Path $probe 'gov' 'root'
            $null = New-Item -ItemType Directory -Path $moduleDir -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $moduleDir 'tests') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'nested') -Force
            Set-Content -LiteralPath (Join-Path $moduleDir 'main.tf') -Value "terraform {}`n" -NoNewline
            Set-Content -LiteralPath (Join-Path $root '.gitignore') -Value "*.tfstate`n" -NoNewline
            Set-Content -LiteralPath (Join-Path $root 'nested' 'SECURITY.md') -Value "# Security`n" -NoNewline

            $result = Invoke-AvmSync -Path $moduleDir -Ecosystem terraform -ManagedFilesLocalPath (Join-Path $probe 'gov')

            $result.PSObject.Properties['Status'].Value   | Should -Be 'pass'
            @($result.PSObject.Properties['Added'].Value) | Should -Be @('.gitignore', 'nested/SECURITY.md')
            Test-Path (Join-Path $moduleDir '.gitignore')                | Should -BeTrue
            Test-Path (Join-Path $moduleDir 'nested' 'SECURITY.md')      | Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
