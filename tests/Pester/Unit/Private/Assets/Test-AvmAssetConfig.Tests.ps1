#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    function script:NewValidConfig {
        @{
            schemaVersion = 1
            assets        = @{
                'aprl-policies' = @{
                    source = 'https://github.com/Azure/Azure-Proactive-Resiliency-Library-v2.git'
                    ref    = 'main'
                    path   = 'azure-resources'
                }
                'avmsec-policies' = @{
                    source = 'https://github.com/Azure/example/archive/v1.0.0.tar.gz'
                    sha256 = ('a' * 64)
                    type   = 'archive'
                }
            }
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Test-AvmAssetConfig' {
    Context 'valid config' {
        It 'accepts an empty assets map' {
            InModuleScope 'Avm.Authoring' {
                Test-AvmAssetConfig -Config @{ schemaVersion = 1; assets = @{} } | Should -BeTrue
            }
        }

        It 'accepts a fully populated multi-asset entry' {
            $cfg = script:NewValidConfig
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $cfg } {
                param($C)
                Test-AvmAssetConfig -Config $C | Should -BeTrue
            }
        }

        It 'accepts an asset that has both ref and sha256' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'mixed-pinning' = @{
                            source = 'https://example.com/x.tar.gz'
                            ref    = 'v1.0.0'
                            sha256 = ('b' * 64)
                        }
                    }
                }
                Test-AvmAssetConfig -Config $cfg | Should -BeTrue
            }
        }

        It 'accepts a file:// source when -AllowFileUrls is set' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'fixture' = @{
                            source = 'file:///tmp/fixture.tar.gz'
                            sha256 = ('c' * 64)
                        }
                    }
                }
                Test-AvmAssetConfig -Config $cfg -AllowFileUrls | Should -BeTrue
            }
        }
    }

    Context 'top-level schema enforcement' {
        It 'rejects a missing schemaVersion' {
            InModuleScope 'Avm.Authoring' {
                { Test-AvmAssetConfig -Config @{ assets = @{} } } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects schemaVersion not equal to 1' {
            InModuleScope 'Avm.Authoring' {
                { Test-AvmAssetConfig -Config @{ schemaVersion = 2; assets = @{} } } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a missing assets map' {
            InModuleScope 'Avm.Authoring' {
                { Test-AvmAssetConfig -Config @{ schemaVersion = 1 } } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a non-hashtable assets value' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{ schemaVersion = 1; assets = 'not-a-hashtable' }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }
    }

    Context 'asset descriptor enforcement' {
        It 'rejects an asset name that is not lowercase kebab-case' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'BadName' = @{ source = 'https://example.com/x.git'; ref = 'main' }
                    }
                }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a non-hashtable descriptor' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{ 'oops' = 'not-a-hashtable' }
                }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an unknown descriptor key' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'aprl-policies' = @{
                            source  = 'https://example.com/x.git'
                            ref     = 'main'
                            unknown = 'whatever'
                        }
                    }
                }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a missing source' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'aprl-policies' = @{ ref = 'main' }
                    }
                }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an empty source' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'aprl-policies' = @{ source = '   '; ref = 'main' }
                    }
                }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a non-https source by default' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'aprl-policies' = @{
                            source = 'http://example.com/x.git'
                            ref    = 'main'
                        }
                    }
                }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a file:// source without -AllowFileUrls' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'fixture' = @{
                            source = 'file:///tmp/x.tar.gz'
                            sha256 = ('d' * 64)
                        }
                    }
                }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an asset with neither ref nor sha256' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'aprl-policies' = @{ source = 'https://example.com/x.git' }
                    }
                }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects a sha256 that is not 64-char lowercase hex' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'aprl-policies' = @{
                            source = 'https://example.com/x.tar.gz'
                            sha256 = 'TOO-SHORT'
                        }
                    }
                }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an unsupported type' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'aprl-policies' = @{
                            source = 'https://example.com/x.git'
                            ref    = 'main'
                            type   = 'svn'
                        }
                    }
                }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }

        It 'rejects an empty path' {
            InModuleScope 'Avm.Authoring' {
                $cfg = @{
                    schemaVersion = 1
                    assets        = @{
                        'aprl-policies' = @{
                            source = 'https://example.com/x.git'
                            ref    = 'main'
                            path   = '   '
                        }
                    }
                }
                { Test-AvmAssetConfig -Config $cfg } |
                    Should -Throw -ExceptionType ([System.Data.DataException])
            }
        }
    }
}
