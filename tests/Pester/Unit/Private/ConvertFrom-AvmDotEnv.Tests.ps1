#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-AvmDotEnv' {
    BeforeEach {
        $script:envPath = Join-Path $TestDrive '.env'
    }

    It 'returns an empty hashtable when the file is missing' {
        $missing = Join-Path $TestDrive 'does-not-exist.env'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $missing } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result | Should -BeOfType ([hashtable])
        $result.Count | Should -Be 0
    }

    It 'returns an empty hashtable for an empty file' {
        Set-Content -LiteralPath $script:envPath -Value '' -Encoding utf8
        $p = $script:envPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result.Count | Should -Be 0
    }

    It 'parses a simple KEY=VALUE line' {
        Set-Content -LiteralPath $script:envPath -Value 'FOO=bar' -Encoding utf8
        $p = $script:envPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result['FOO'] | Should -Be 'bar'
        $result.Count   | Should -Be 1
    }

    It 'ignores blank lines and comment lines' {
        Set-Content -LiteralPath $script:envPath -Value @(
            ''
            '   '
            '# a comment'
            '   # indented comment'
            'FOO=bar'
        ) -Encoding utf8
        $p = $script:envPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result.Count | Should -Be 1
        $result['FOO'] | Should -Be 'bar'
    }

    It 'strips a leading export keyword' {
        Set-Content -LiteralPath $script:envPath -Value 'export FOO=bar' -Encoding utf8
        $p = $script:envPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result['FOO'] | Should -Be 'bar'
    }

    It 'trims whitespace around the key and an unquoted value' {
        Set-Content -LiteralPath $script:envPath -Value '  FOO  =   bar  ' -Encoding utf8
        $p = $script:envPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result.ContainsKey('FOO') | Should -BeTrue
        $result['FOO'] | Should -Be 'bar'
    }

    It 'strips a single matching pair of double quotes' {
        Set-Content -LiteralPath $script:envPath -Value 'FOO="bar baz"' -Encoding utf8
        $p = $script:envPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result['FOO'] | Should -Be 'bar baz'
    }

    It 'strips a single matching pair of single quotes' {
        Set-Content -LiteralPath $script:envPath -Value "FOO='bar baz'" -Encoding utf8
        $p = $script:envPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result['FOO'] | Should -Be 'bar baz'
    }

    It 'splits on the first = so values may contain =' {
        Set-Content -LiteralPath $script:envPath -Value 'CONN=Endpoint=sb://x/;Key=abc==' -Encoding utf8
        $p = $script:envPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result['CONN'] | Should -Be 'Endpoint=sb://x/;Key=abc=='
    }

    It 'ignores a line with no separator' {
        Set-Content -LiteralPath $script:envPath -Value @('NOTAPAIR', 'FOO=bar') -Encoding utf8
        $p = $script:envPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result.Count | Should -Be 1
        $result['FOO'] | Should -Be 'bar'
    }

    It 'ignores a line with an empty key' {
        Set-Content -LiteralPath $script:envPath -Value @('=orphan', 'FOO=bar') -Encoding utf8
        $p = $script:envPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result.Count | Should -Be 1
        $result['FOO'] | Should -Be 'bar'
    }

    It 'keeps an empty value' {
        Set-Content -LiteralPath $script:envPath -Value 'FOO=' -Encoding utf8
        $p = $script:envPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
            param($P)
            ConvertFrom-AvmDotEnv -Path $P
        }
        $result.ContainsKey('FOO') | Should -BeTrue
        $result['FOO'] | Should -Be ''
    }
}
