#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmHttp' {
    BeforeAll {
        # Make sure we never accidentally hit the real network during unit tests.
        $script:savedOffline = if (Test-Path Env:\AVM_OFFLINE) { $env:AVM_OFFLINE } else { $null }
        $script:savedMirror = if (Test-Path Env:\AVM_MIRROR) { $env:AVM_MIRROR } else { $null }
    }

    AfterAll {
        if ($null -eq $script:savedOffline) { Remove-Item Env:\AVM_OFFLINE -ErrorAction SilentlyContinue }
        else { $env:AVM_OFFLINE = $script:savedOffline }
        if ($null -eq $script:savedMirror) { Remove-Item Env:\AVM_MIRROR -ErrorAction SilentlyContinue }
        else { $env:AVM_MIRROR = $script:savedMirror }
    }

    Context 'file:// fixture downloads' {
        BeforeAll {
            $script:payloadDir = Join-Path $TestDrive 'payload'
            New-Item -ItemType Directory -Path $script:payloadDir | Out-Null
            $script:payloadPath = Join-Path $script:payloadDir 'thing.bin'
            Set-Content -LiteralPath $script:payloadPath -Value 'hello-avm' -NoNewline -Encoding utf8
            $script:expectedSha = (Get-FileHash -LiteralPath $script:payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $urlPath = ($script:payloadPath -replace '\\', '/')
            if ($urlPath -notmatch '^/') { $urlPath = '/' + $urlPath }
            $script:fileUrl = "file://$urlPath"
        }

        It 'copies the fixture and returns the destination path' {
            $dest = Join-Path $TestDrive 'out.bin'
            $url = $script:fileUrl
            $sha = $script:expectedSha
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ U = $url; D = $dest; S = $sha } {
                param($U, $D, $S)
                Invoke-AvmHttp -Url $U -Destination $D -ExpectedSha256 $S
            }
            $result | Should -Be $dest
            Test-Path -LiteralPath $dest | Should -BeTrue
            (Get-Content -LiteralPath $dest -Raw) | Should -Be 'hello-avm'
        }

        It 'throws AvmToolException on SHA256 mismatch and removes the .partial file' {
            $dest = Join-Path $TestDrive 'mismatch.bin'
            $url = $script:fileUrl
            $bogus = ('0' * 64)
            $err = InModuleScope 'Avm.Authoring' -Parameters @{ U = $url; D = $dest; S = $bogus } {
                param($U, $D, $S)
                try {
                    Invoke-AvmHttp -Url $U -Destination $D -ExpectedSha256 $S
                    return $null
                }
                catch {
                    return $_.Exception
                }
            }
            $err | Should -Not -BeNullOrEmpty
            $err.GetType().Name | Should -Be 'AvmToolException'
            $err.Code | Should -Be 'AVM1011'

            Test-Path -LiteralPath "$dest.partial" | Should -BeFalse
            Test-Path -LiteralPath $dest | Should -BeFalse
        }

        It 'creates the destination directory if missing' {
            $dest = Join-Path $TestDrive 'nested' 'sub' 'out.bin'
            $url = $script:fileUrl
            $sha = $script:expectedSha
            InModuleScope 'Avm.Authoring' -Parameters @{ U = $url; D = $dest; S = $sha } {
                param($U, $D, $S)
                Invoke-AvmHttp -Url $U -Destination $D -ExpectedSha256 $S | Out-Null
            }
            Test-Path -LiteralPath $dest | Should -BeTrue
        }
    }

    Context 'input validation' {
        It 'rejects an ftp:// URL' {
            {
                InModuleScope 'Avm.Authoring' {
                    Invoke-AvmHttp -Url 'ftp://example.com/x' -Destination 'q.bin' -ExpectedSha256 ('a' * 64)
                }
            } | Should -Throw -ExceptionType ([System.ArgumentException])
        }

        It 'rejects a non-hex ExpectedSha256' {
            {
                InModuleScope 'Avm.Authoring' {
                    Invoke-AvmHttp -Url 'https://example.com/x' -Destination 'q.bin' -ExpectedSha256 'short'
                }
            } | Should -Throw -ExceptionType ([System.ArgumentException])
        }
    }

    Context 'AVM_OFFLINE gate' {
        It 'refuses https downloads when AVM_OFFLINE=1 (throws AvmConfigurationException)' {
            $env:AVM_OFFLINE = '1'
            try {
                $err = InModuleScope 'Avm.Authoring' {
                    try {
                        Invoke-AvmHttp -Url 'https://example.com/x' -Destination 'q.bin' -ExpectedSha256 ('a' * 64)
                        return $null
                    }
                    catch {
                        return $_.Exception
                    }
                }
                $err | Should -Not -BeNullOrEmpty
                $err.GetType().Name | Should -Be 'AvmConfigurationException'
                $err.Code | Should -Be 'AVM1001'
            }
            finally {
                Remove-Item Env:\AVM_OFFLINE -ErrorAction SilentlyContinue
            }
        }

        It 'still allows file:// when AVM_OFFLINE=1' {
            $payloadPath = Join-Path $TestDrive 'offline-fixture.bin'
            Set-Content -LiteralPath $payloadPath -Value 'still-here' -NoNewline -Encoding utf8
            $sha = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $urlPath = ($payloadPath -replace '\\', '/')
            if ($urlPath -notmatch '^/') { $urlPath = '/' + $urlPath }
            $url = "file://$urlPath"
            $dest = Join-Path $TestDrive 'offline-out.bin'

            $env:AVM_OFFLINE = '1'
            try {
                InModuleScope 'Avm.Authoring' -Parameters @{ U = $url; D = $dest; S = $sha } {
                    param($U, $D, $S)
                    Invoke-AvmHttp -Url $U -Destination $D -ExpectedSha256 $S | Out-Null
                }
                Test-Path -LiteralPath $dest | Should -BeTrue
            }
            finally {
                Remove-Item Env:\AVM_OFFLINE -ErrorAction SilentlyContinue
            }
        }
    }
}
