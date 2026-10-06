#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..')).Path
    Import-Module (Join-Path $root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepDocsConfiguration package defaults' {
    It 'uses the packaged template without writing caller files: <Kind>' -ForEach @(
        @{ Kind = 'no config'; Json = $null }
        @{ Kind = 'compiler config'; Json = '{"analyzers":{"core":{"enabled":true}}}' }
        @{ Kind = 'documentation options'; Json = '{"documentation":{"examples":{"include":true}}}' }
    ) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $path
        if ($null -ne $Json) {
            [IO.File]::WriteAllText((Join-Path $path 'bicepconfig.json'), $Json)
        }
        InModuleScope Avm.Authoring -Parameters @{ Path = $path } {
            param($Path)
            $before = @(Get-ChildItem -LiteralPath $Path -Recurse -File | ForEach-Object FullName)
            $result = Get-AvmBicepDocsConfiguration -ModulePath $Path
            $canonical = Get-AvmBicepDocsTemplate
            $result.TemplatePath | Should -BeExactly $canonical.Path
            $result.Hash | Should -BeExactly $canonical.Hash
            $after = @(Get-ChildItem -LiteralPath $Path -Recurse -File | ForEach-Object FullName)
            ($after -join '|') | Should -BeExactly ($before -join '|')
        }
    }

    It 'rejects malformed explicit configuration: <Json>' -ForEach @(
        @{ Json = '[]' }
        @{ Json = '{"documentation":null}' }
        @{ Json = '{"documentation":{"template":null}}' }
        @{ Json = '{"documentation":{"template":{}}}' }
        @{ Json = '{"documentation":{"template":{"file":""}}}' }
        @{ Json = '{"documentation":{"template":{"file":"missing.scriban"}}}' }
    ) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $path
        [IO.File]::WriteAllText((Join-Path $path 'bicepconfig.json'), $Json)
        InModuleScope Avm.Authoring -Parameters @{ Path = $path } {
            param($Path)
            { Get-AvmBicepDocsConfiguration -ModulePath $Path } | Should -Throw
        }
    }
}
