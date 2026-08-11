#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    $script:newTarFixture = {
        param(
            [Parameter(Mandatory)]
            [string] $Path,

            [Parameter(Mandatory)]
            [object[]] $Entries
        )

        $archiveStream = [System.IO.File]::Create($Path)
        try {
            $gzipStream = [System.IO.Compression.GZipStream]::new(
                $archiveStream,
                [System.IO.Compression.CompressionLevel]::SmallestSize,
                $true)
            try {
                $writer = [System.Formats.Tar.TarWriter]::new(
                    $gzipStream,
                    [System.Formats.Tar.TarEntryFormat]::Pax,
                    $true)
                try {
                    foreach ($definition in $Entries) {
                        $entryType = [System.Enum]::Parse(
                            [System.Formats.Tar.TarEntryType],
                            $definition.Type)
                        $entry = [System.Formats.Tar.PaxTarEntry]::new(
                            $entryType,
                            $definition.Name)
                        if ($definition.PSObject.Properties['LinkName']) {
                            $entry.LinkName = $definition.LinkName
                        }
                        if ($definition.PSObject.Properties['Content']) {
                            $bytes = [System.Text.Encoding]::UTF8.GetBytes(
                                $definition.Content)
                            $entry.DataStream = [System.IO.MemoryStream]::new(
                                $bytes,
                                $false)
                        }
                        try {
                            $writer.WriteEntry($entry)
                        }
                        finally {
                            if ($null -ne $entry.DataStream) {
                                $entry.DataStream.Dispose()
                            }
                        }
                    }
                }
                finally {
                    $writer.Dispose()
                }
            }
            finally {
                $gzipStream.Dispose()
            }
        }
        finally {
            $archiveStream.Dispose()
        }

        return $Path
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Expand-AvmWindowsTarArchive' {
    It 'materializes deferred symbolic and hard links as regular files' {
        $archivePath = Join-Path $TestDrive 'policy.tar.gz'
        & $script:newTarFixture -Path $archivePath -Entries @(
            [pscustomobject]@{
                Type     = 'SymbolicLink'
                Name     = 'policy/Azure-Proactive-Resiliency-Library-v2/common.utils.rego'
                LinkName = '../common/common.utils.rego'
            },
            [pscustomobject]@{
                Type     = 'HardLink'
                Name     = 'policy/avmsec/common.utils.rego'
                LinkName = 'policy/common/common.utils.rego'
            },
            [pscustomobject]@{
                Type    = 'RegularFile'
                Name    = 'policy/common/common.utils.rego'
                Content = 'package common'
            }
        ) | Out-Null
        $targetDir = Join-Path $TestDrive 'expanded'

        InModuleScope 'Avm.Authoring' -Parameters @{
            ArchivePath = $archivePath
            TargetDir   = $targetDir
        } {
            param($ArchivePath, $TargetDir)
            Expand-AvmWindowsTarArchive `
                -ArchivePath $ArchivePath `
                -TargetDir $TargetDir
        }

        $symbolicCopy = Join-Path $targetDir 'policy/Azure-Proactive-Resiliency-Library-v2/common.utils.rego'
        $hardCopy = Join-Path $targetDir 'policy/avmsec/common.utils.rego'
        (Get-Content -LiteralPath $symbolicCopy -Raw) | Should -Be 'package common'
        (Get-Content -LiteralPath $hardCopy -Raw) | Should -Be 'package common'
        (Get-Item -LiteralPath $symbolicCopy).LinkType | Should -BeNullOrEmpty
        (Get-Item -LiteralPath $hardCopy).LinkType | Should -BeNullOrEmpty
    }

    It 'rejects links whose target escapes the extraction root' {
        $archivePath = Join-Path $TestDrive 'unsafe-link.tar.gz'
        & $script:newTarFixture -Path $archivePath -Entries @(
            [pscustomobject]@{
                Type     = 'SymbolicLink'
                Name     = 'policy/rules/common.rego'
                LinkName = '../../../outside.rego'
            }
        ) | Out-Null
        $targetDir = Join-Path $TestDrive 'unsafe-link-expanded'

        {
            InModuleScope 'Avm.Authoring' -Parameters @{
                ArchivePath = $archivePath
                TargetDir   = $targetDir
            } {
                param($ArchivePath, $TargetDir)
                Expand-AvmWindowsTarArchive `
                    -ArchivePath $ArchivePath `
                    -TargetDir $TargetDir
            }
        } | Should -Throw '*escapes the extraction root*'
    }

    It 'rejects file entries that escape the extraction root' {
        $archivePath = Join-Path $TestDrive 'unsafe-file.tar.gz'
        & $script:newTarFixture -Path $archivePath -Entries @(
            [pscustomobject]@{
                Type    = 'RegularFile'
                Name    = '../outside.rego'
                Content = 'package outside'
            }
        ) | Out-Null
        $targetDir = Join-Path $TestDrive 'unsafe-file-expanded'

        {
            InModuleScope 'Avm.Authoring' -Parameters @{
                ArchivePath = $archivePath
                TargetDir   = $targetDir
            } {
                param($ArchivePath, $TargetDir)
                Expand-AvmWindowsTarArchive `
                    -ArchivePath $ArchivePath `
                    -TargetDir $TargetDir
            }
        } | Should -Throw '*escapes the extraction root*'
    }
}

Describe 'Expand-AvmToolArchive tar.gz dispatch' {
    It 'uses managed extraction on Windows' -Skip:(-not $IsWindows) {
        $archivePath = Join-Path $TestDrive 'dispatch.tar.gz'
        & $script:newTarFixture -Path $archivePath -Entries @(
            [pscustomobject]@{
                Type    = 'RegularFile'
                Name    = 'tool.exe'
                Content = 'tool'
            }
        ) | Out-Null
        $targetDir = Join-Path $TestDrive 'dispatch-expanded'
        New-Item -ItemType Directory -Path $targetDir | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{
            ArchivePath = $archivePath
            TargetDir   = $targetDir
        } {
            param($ArchivePath, $TargetDir)
            Mock Invoke-AvmProcess { throw 'native tar should not run' }

            Expand-AvmToolArchive `
                -ArchivePath $ArchivePath `
                -Archive 'tar.gz' `
                -TargetDir $TargetDir `
                -EntrypointBasename 'tool'

            Should -Invoke Invoke-AvmProcess -Times 0 -Exactly
        }

        Test-Path -LiteralPath (Join-Path $targetDir 'tool.exe') |
            Should -BeTrue
    }
}
