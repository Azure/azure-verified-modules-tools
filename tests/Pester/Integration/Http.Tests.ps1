#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Integration: real HTTPS download through Invoke-AvmHttp against the actual
# upstream release for the smallest tool we manage (terraform-docs).
# Catches lock-file SHA drift, GitHub URL template breakage, and
# TLS / network-stack regressions on a runner OS.
#
# Tagged 'Integration' so the integration task picks it up and so it stays out of
# the Unit and Component runs. Honour AVM_OFFLINE so an offline build
# is never blocked by integration.

Describe 'Integration: Invoke-AvmHttp against real upstream releases' -Tag 'Integration' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module $script:moduleManifest -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    # Inline the AVM_OFFLINE check because Pester 5 evaluates -Skip: at
    # discovery time, before BeforeAll has had a chance to set script
    # variables. Honouring AVM_OFFLINE here means an offline runner that
    # accidentally invokes `./build.ps1 integration` reports the test as Skipped
    # rather than failing on the missing network.
    It 'downloads terraform-docs from GitHub and verifies the locked SHA256' -Skip:((Test-Path Env:\AVM_OFFLINE) -and ($env:AVM_OFFLINE -eq '1')) {
        $dest = Join-Path $TestDrive 'terraform-docs-archive'

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Destination = $dest } {
            param($Destination)

            $lockPath = Join-Path $PSScriptRoot 'Resources' 'tools.lock.psd1'
            # PSScriptRoot inside the module-scope block resolves to the
            # module root because the .psm1 dot-sources the private files
            # from there at import time. Fall back to a discovery walk if
            # someone re-arranges the layout.
            if (-not (Test-Path -LiteralPath $lockPath)) {
                $lockPath = (Get-Module Avm.Authoring).ModuleBase |
                    Join-Path -ChildPath 'Resources' |
                    Join-Path -ChildPath 'tools.lock.psd1'
            }

            $lock = Read-AvmToolsLock -Path $lockPath
            $tool = $lock.tools | Where-Object { $_.name -eq 'terraform-docs' }
            if (-not $tool) { throw "terraform-docs not present in lock file at $lockPath" }

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
