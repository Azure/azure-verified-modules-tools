#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-AvmMirrorUrl' {
    Context 'pass-through cases' {
        It 'returns Source unchanged when Mirror is $null' {
            $result = InModuleScope 'Avm.Authoring' {
                Resolve-AvmMirrorUrl -Source 'https://releases.hashicorp.com/terraform/1.9.5/foo.zip' -Mirror $null
            }
            $result | Should -Be 'https://releases.hashicorp.com/terraform/1.9.5/foo.zip'
        }

        It 'returns Source unchanged when Mirror is empty string' {
            $result = InModuleScope 'Avm.Authoring' {
                Resolve-AvmMirrorUrl -Source 'https://example.com/a/b' -Mirror ''
            }
            $result | Should -Be 'https://example.com/a/b'
        }

        It 'returns Source unchanged when Mirror is whitespace' {
            $result = InModuleScope 'Avm.Authoring' {
                Resolve-AvmMirrorUrl -Source 'https://example.com/a/b' -Mirror '   '
            }
            $result | Should -Be 'https://example.com/a/b'
        }

        It 'never rewrites a file:// source even when Mirror is set' {
            $result = InModuleScope 'Avm.Authoring' {
                Resolve-AvmMirrorUrl -Source 'file:///tmp/fixture.bin' -Mirror 'https://m.example.com'
            }
            $result | Should -Be 'file:///tmp/fixture.bin'
        }

        It 'does not rewrite non-https/non-file source (defensive)' {
            $result = InModuleScope 'Avm.Authoring' {
                Resolve-AvmMirrorUrl -Source 'ftp://example.com/foo' -Mirror 'https://m.example.com'
            }
            $result | Should -Be 'ftp://example.com/foo'
        }
    }

    Context 'rewrite preserves the mirror path prefix' {
        It 'strips trailing slash from mirror path and appends source path-and-query' {
            $result = InModuleScope 'Avm.Authoring' {
                Resolve-AvmMirrorUrl `
                    -Source 'https://releases.hashicorp.com/terraform/1.9.5/terraform_1.9.5_linux_amd64.zip' `
                    -Mirror 'https://m.example.com/proxy/'
            }
            $result | Should -Be 'https://m.example.com/proxy/terraform/1.9.5/terraform_1.9.5_linux_amd64.zip'
        }

        It 'handles a mirror with no path (host only)' {
            $result = InModuleScope 'Avm.Authoring' {
                Resolve-AvmMirrorUrl `
                    -Source 'https://releases.hashicorp.com/terraform/1.9.5/foo.zip' `
                    -Mirror 'https://m.example.com'
            }
            $result | Should -Be 'https://m.example.com/terraform/1.9.5/foo.zip'
        }

        It 'preserves the source query string' {
            $result = InModuleScope 'Avm.Authoring' {
                Resolve-AvmMirrorUrl `
                    -Source 'https://example.com/asset.zip?token=abc&v=1' `
                    -Mirror 'https://m.example.com/proxy'
            }
            $result | Should -Be 'https://m.example.com/proxy/asset.zip?token=abc&v=1'
        }

        It 'preserves the mirror port' {
            $result = InModuleScope 'Avm.Authoring' {
                Resolve-AvmMirrorUrl `
                    -Source 'https://example.com/a/b/foo.zip' `
                    -Mirror 'https://m.example.com:8443/proxy'
            }
            $result | Should -Be 'https://m.example.com:8443/proxy/a/b/foo.zip'
        }
    }

    Context 'validation' {
        It 'throws AvmConfigurationException when Mirror is http://' {
            $err = InModuleScope 'Avm.Authoring' {
                try {
                    Resolve-AvmMirrorUrl -Source 'https://example.com/x' -Mirror 'http://m.example.com'
                    return $null
                }
                catch {
                    return $_.Exception
                }
            }
            $err | Should -Not -BeNullOrEmpty
            $err.GetType().Name | Should -Be 'AvmConfigurationException'
            $err.Code | Should -Be 'AVM1001'
            $err.Message | Should -Match "https://"
        }

        It 'throws AvmConfigurationException when Mirror is not a valid absolute URL' {
            $err = InModuleScope 'Avm.Authoring' {
                try {
                    Resolve-AvmMirrorUrl -Source 'https://example.com/x' -Mirror 'https:// not a url'
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
    }
}
