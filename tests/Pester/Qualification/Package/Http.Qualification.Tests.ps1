#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: Invoke-AvmHttp against real upstream releases' -Tag Qualification {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module $script:moduleManifest -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'downloads terraform-docs from GitHub and verifies the locked SHA256' {
        $dest = Join-Path $TestDrive 'terraform-docs-archive'

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Destination = $dest } {
            param($Destination)

            $pinsPath = Join-Path $PSScriptRoot 'Resources' 'avm.pins.jsonc'
            # PSScriptRoot inside the module-scope block resolves to the
            # module root because the .psm1 dot-sources the private files
            # from there at import time. Fall back to a discovery walk if
            # someone re-arranges the layout.
            if (-not (Test-Path -LiteralPath $pinsPath)) {
                $pinsPath = (Get-Module Avm.Authoring).ModuleBase |
                    Join-Path -ChildPath 'Resources' |
                    Join-Path -ChildPath 'avm.pins.jsonc'
            }

            $pins = Read-AvmPins -Path $pinsPath
            $tool = $pins.tools | Where-Object { $_.name -eq 'terraform-docs' }
            if (-not $tool) { throw "terraform-docs not present in the pin manifest at $pinsPath" }

            $platform = Get-AvmToolPlatform
            if (-not $tool.sha256.ContainsKey($platform)) {
                throw "terraform-docs has no sha256 for current platform '$platform'."
            }

            $osPart, $archPart = $platform.Split('-', 2)
            $url = $tool.urlTemplate.
                Replace('{version}', $tool.version).
                Replace('{os}', $osPart).
                Replace('{arch}', $archPart)
            $resolvedArchive = if ($tool.ContainsKey('archives') -and $tool.archives.ContainsKey($platform)) {
                [string]$tool.archives[$platform]
            } else { $tool.archive }
            $ext = switch ($resolvedArchive) {
                'zip'    { '.zip' }
                'tar.gz' { '.tar.gz' }
                'raw'    { '' }
            }
            $url = $url.Replace('{ext}', $ext)

            $sha = $tool.sha256[$platform]
            $path = Invoke-AvmHttp -Url $url -Destination $Destination -ExpectedSha256 $sha -TimeoutSec 120

            [pscustomobject]@{
                Url      = $url
                Sha      = $sha
                Platform = $platform
                Version  = $tool.version
                Path     = $path
            }
        }

        $result.Url        | Should -Match '^https://github\.com/terraform-docs/terraform-docs/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/terraform-docs-v[0-9]+\.[0-9]+\.[0-9]+-(windows|linux|darwin)-(amd64|arm64)\.(zip|tar\.gz)$'
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        (Get-Item -LiteralPath $result.Path).Length | Should -BeGreaterThan 100000
    }
}
