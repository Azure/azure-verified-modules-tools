#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..')).Path
    $script:previousTemplate = Join-Path $root 'tests' 'fixtures' 'bicep-docs-template' 'avm-readme-v1.scriban'
    Import-Module (Join-Path $root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepDocsConfiguration package defaults' {
    It 'accepts exact current and previous official templates, but rejects modifications' {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $path
        $template = Join-Path $path 'avm-readme-v1.scriban'
        [IO.File]::WriteAllText((Join-Path $path 'bicepconfig.json'),
            '{"documentation":{"template":{"file":"avm-readme-v1.scriban"}}}')
        Copy-Item -LiteralPath $script:previousTemplate -Destination $template
        InModuleScope Avm.Authoring -Parameters @{ Path = $path; Template = $template } {
            param($Path, $Template)
            (Get-FileHash -LiteralPath $Template).Hash |
                Should -BeExactly '6FAEB739CC2CA368FB4CC91E6A936852A9CFDFA23BC9E76A5B137990E6D1CD1A'
            $current = Get-AvmBicepDocsTemplate
            $old = Get-AvmBicepDocsConfiguration -ModulePath $Path
            $old.UsesPackageTemplate | Should -BeTrue
            $old.TemplatePath | Should -BeExactly $current.Path
            $old.Hash | Should -BeExactly $current.Hash
            Copy-Item -LiteralPath $current.Path -Destination $Template -Force
            $new = Get-AvmBicepDocsConfiguration -ModulePath $Path
            $new.UsesPackageTemplate | Should -BeFalse
            $new.TemplatePath | Should -BeExactly $Template
            [IO.File]::AppendAllText($Template, 'tampered')
            { Get-AvmBicepDocsConfiguration -ModulePath $Path } | Should -Throw '*differs from the packaged*'
        }
    }

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
