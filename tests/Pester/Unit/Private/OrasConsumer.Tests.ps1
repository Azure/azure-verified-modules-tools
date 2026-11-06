#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'ORAS pin' {
    It 'uses the official release archives and verified hashes for every managed platform' {
        $pin = InModuleScope 'Avm.Authoring' {
            Read-AvmPins | ForEach-Object tools | Where-Object name -ceq 'oras'
        }

        $pin.version | Should -Be '1.3.6'
        $pin.urlTemplate | Should -Be 'https://github.com/oras-project/oras/releases/download/v{version}/oras_{version}_{os}_{arch}{ext}'
        $pin.archives.'windows-amd64' | Should -Be 'zip'
        $pin.archives.'windows-arm64' | Should -Be 'zip'
        foreach ($platform in @('linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64')) {
            $pin.archives[$platform] | Should -Be 'tar.gz'
        }
        $pin.sha256.'windows-amd64' | Should -Be 'ec3d19f386d5d2f0892288772d7b242475a05332aafa64b6773378ca771d76d3'
        $pin.sha256.'windows-arm64' | Should -Be '2b6104e9b9da4ca8c395cc15b8fbbbcbc072df77242a146e0d1639bacc4ed0cb'
        $pin.sha256.'linux-amd64' | Should -Be '66fb0ad7206f3f6fa77ed5b552049d364ccf4b50b1684554f731f76302b52ca0'
        $pin.sha256.'linux-arm64' | Should -Be 'b84269e78dfc2d5329a4aab373da3200de95e6c138338cf6c66c10c0a3f248c1'
        $pin.sha256.'darwin-amd64' | Should -Be '844e26430aa0afe2c40fdbddafc3b39ef968a6d41955b7380684bd02907fa397'
        $pin.sha256.'darwin-arm64' | Should -Be 'e2b25a53234e2471c5fc81936f957fa612065ab559c21834c02d8bfbc2f62b30'
    }
}

Describe 'Invoke-AvmOrasPull' {
    It 'pulls an immutable digest for the requested OCI platform' {
        $destination = Join-Path $TestDrive 'payload'
        New-Item -ItemType Directory -Path $destination | Out-Null
        $reference = 'mcr.microsoft.com/avm/tools/tflintruleset@sha256:' + ('a' * 64)

        InModuleScope 'Avm.Authoring' -Parameters @{ Destination = $destination; Reference = $reference } {
            param($Destination, $Reference)
            Mock Resolve-AvmTool { [pscustomobject]@{ Path = 'oras-fixture' } }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }

            Invoke-AvmOrasPull -Reference $Reference -Platform 'windows-arm64' -Destination $Destination | Out-Null

            Should -Invoke Resolve-AvmTool -Exactly 1 -ParameterFilter { $Name -eq 'oras' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq 'oras-fixture' -and
                ($ArgumentList -join '|') -ceq ("pull|--platform|windows/arm64|--output|$Destination|$Reference") -and
                $WorkingDirectory -eq $Destination -and
                $RetryNetworkFailure
            }
        }
    }

    It 'rejects mutable references before resolving ORAS' {
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $destination | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ Destination = $destination } {
            param($Destination)
            Mock Resolve-AvmTool { throw 'ORAS must not be resolved.' }

            { Invoke-AvmOrasPull -Reference 'mcr.microsoft.com/avm/tools/mapotf:1.0.0' -Platform 'linux-amd64' -Destination $Destination } |
                Should -Throw -ExceptionType ([System.ArgumentException])
            Should -Invoke Resolve-AvmTool -Exactly 0
        }
    }
}

Describe 'Install-AvmTflintPluginArchive' {
    It 'verifies and stages an AVM ruleset archive in TFLint plugin cache layout' {
        $source = Join-Path $TestDrive 'source'
        $cache = Join-Path $TestDrive 'plugins'
        New-Item -ItemType Directory -Path $source | Out-Null
        $name = if ($IsWindows) { 'tflint-ruleset-avm.exe' } else { 'tflint-ruleset-avm' }
        $binary = Join-Path $source $name
        [System.IO.File]::WriteAllText($binary, 'plugin')
        $archive = Join-Path $TestDrive 'tflint-ruleset-avm_windows_amd64.zip'
        Compress-Archive -LiteralPath $binary -DestinationPath $archive
        $checksums = Join-Path $TestDrive 'checksums.txt'
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText($checksums, "$hash  $([System.IO.Path]::GetFileName($archive))")

        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            Archive = $archive; Checksums = $checksums; Cache = $cache
        } {
            param($Archive, $Checksums, $Cache)
            Mock Get-AuthenticodeSignature {
                [pscustomobject]@{ Status = [System.Management.Automation.SignatureStatus]::Valid }
            }
            Install-AvmTflintPluginArchive `
                -ArchivePath $Archive `
                -ChecksumsPath $Checksums `
                -PluginCacheDirectory $Cache `
                -Version '1.4.1'
        }

        $result.Action | Should -Be 'installed'
        $result.Path | Should -Be (Join-Path $cache "github.com/Azure/tflint-ruleset-avm/1.4.1/$name")
        (Get-Content -LiteralPath $result.Path -Raw) | Should -Be 'plugin'

        $cached = InModuleScope 'Avm.Authoring' -Parameters @{
            Archive = $archive; Checksums = $checksums; Cache = $cache
        } {
            param($Archive, $Checksums, $Cache)
            Mock Get-AuthenticodeSignature {
                [pscustomobject]@{ Status = [System.Management.Automation.SignatureStatus]::Valid }
            }
            Install-AvmTflintPluginArchive `
                -ArchivePath $Archive `
                -ChecksumsPath $Checksums `
                -PluginCacheDirectory $Cache `
                -Version '1.4.1'
        }
        $cached.Action | Should -Be 'cache-hit'
    }

    It 'refuses a release archive whose checksum does not match' {
        $archive = Join-Path $TestDrive 'tflint-ruleset-avm_windows_amd64.zip'
        [System.IO.File]::WriteAllText($archive, 'not-an-archive')
        $checksums = Join-Path $TestDrive 'checksums.txt'
        [System.IO.File]::WriteAllText($checksums, ('0' * 64) + '  ' + [System.IO.Path]::GetFileName($archive))

        {
            InModuleScope 'Avm.Authoring' -Parameters @{
                Archive = $archive; Checksums = $checksums; Cache = (Join-Path $TestDrive 'plugins')
            } {
                param($Archive, $Checksums, $Cache)
                Install-AvmTflintPluginArchive `
                    -ArchivePath $Archive `
                    -ChecksumsPath $Checksums `
                    -PluginCacheDirectory $Cache `
                    -Version '1.4.1'
            }
        } | Should -Throw -ExceptionType ([System.IO.InvalidDataException])
    }

    It 'rejects an unsigned Windows plugin after archive verification' -Skip:(-not $IsWindows) {
        $source = Join-Path $TestDrive 'unsigned-source'
        $cache = Join-Path $TestDrive 'unsigned-plugins'
        New-Item -ItemType Directory -Path $source | Out-Null
        $binary = Join-Path $source 'tflint-ruleset-avm.exe'
        [System.IO.File]::WriteAllText($binary, 'plugin')
        $archive = Join-Path $TestDrive 'tflint-ruleset-avm_unsigned_windows_amd64.zip'
        Compress-Archive -LiteralPath $binary -DestinationPath $archive
        $checksums = Join-Path $TestDrive 'unsigned-checksums.txt'
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText($checksums, "$hash  $([System.IO.Path]::GetFileName($archive))")

        {
            InModuleScope 'Avm.Authoring' -Parameters @{
                Archive = $archive; Checksums = $checksums; Cache = $cache
            } {
                param($Archive, $Checksums, $Cache)
                Mock Get-AuthenticodeSignature {
                    [pscustomobject]@{ Status = [System.Management.Automation.SignatureStatus]::NotSigned }
                }
                Install-AvmTflintPluginArchive `
                    -ArchivePath $Archive `
                    -ChecksumsPath $Checksums `
                    -PluginCacheDirectory $Cache `
                    -Version '1.4.1'
            }
        } | Should -Throw -ExceptionType ([System.IO.InvalidDataException])
    }
}
