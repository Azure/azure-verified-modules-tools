Describe 'Get-AvmModuleContext' {
    BeforeAll {
        $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-context-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'detects a Bicep monorepo at the authoritative root' {
        New-Item -ItemType Directory -Path (Join-Path $script:testRoot 'avm' 'res') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:testRoot 'bicepconfig.json') -Value '{}'

        $context = Get-AvmModuleContext -Path $script:testRoot

        $context.Kind | Should -Be 'bicep-monorepo'
        $context.Root | Should -Be $script:testRoot
        $context.Ecosystem | Should -Be 'bicep'
        $context.Scope | Should -BeNullOrEmpty
    }

    It 'detects direct Bicep source without version.json' {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.bicep') -Value 'param name string'

        $context = Get-AvmModuleContext -Path $script:testRoot

        $context.Kind | Should -Be 'bicep-module'
        $context.Root | Should -Be $script:testRoot
        $context.Ecosystem | Should -Be 'bicep'
    }

    It 'derives Bicep scope without changing the authoritative root' {
        $moduleRoot = Join-Path $script:testRoot 'avm' 'res' 'network' 'virtual-network'
        New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $moduleRoot 'main.bicep') -Value 'param name string'

        $context = Get-AvmModuleContext -Path $moduleRoot

        $context.Kind | Should -Be 'bicep-module'
        $context.Root | Should -Be $moduleRoot
        $context.Scope | Should -Be 'res'
    }

    It 'detects a Terraform repository from terraform.tf without convention folders' {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'terraform.tf') -Value 'terraform {}'

        $context = Get-AvmModuleContext -Path $script:testRoot

        $context.Kind | Should -Be 'terraform-module-repo'
        $context.Root | Should -Be $script:testRoot
        $context.Ecosystem | Should -Be 'terraform'
    }

    It 'detects a Terraform module path from direct source without tests' {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.tf') -Value 'resource "null_resource" "example" {}'

        $context = Get-AvmModuleContext -Path $script:testRoot

        $context.Kind | Should -Be 'terraform-module-path'
        $context.Root | Should -Be $script:testRoot
        $context.Ecosystem | Should -Be 'terraform'
    }

    It 'does not use convention folders to select the Terraform kind' {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.tf') -Value 'resource "null_resource" "example" {}'
        New-Item -ItemType Directory -Path (Join-Path $script:testRoot 'examples') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:testRoot 'tests') -Force | Out-Null

        (Get-AvmModuleContext -Path $script:testRoot).Kind | Should -Be 'terraform-module-path'
    }

    It 'uses the current directory as the authoritative root by default' {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.tf') -Value 'resource "null_resource" "example" {}'
        Push-Location $script:testRoot
        try {
            (Get-AvmModuleContext).Root | Should -Be $script:testRoot
        }
        finally {
            Pop-Location
        }
    }

    It 'does not discover source from a parent directory' {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'terraform.tf') -Value 'terraform {}'
        $child = Join-Path $script:testRoot 'src'
        New-Item -ItemType Directory -Path $child | Out-Null

        { Get-AvmModuleContext -Path $child } |
            Should -Throw -ExpectedMessage '*authoritative module root*'
    }

    It 'does not allow a parent override to hijack a nested source root' {
        New-Item -ItemType Directory -Path (Join-Path $script:testRoot '.avm') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:testRoot '.avm' 'context.psd1') -Value @'
@{
    Ecosystem = 'bicep'
    Kind = 'bicep-monorepo'
}
'@
        $child = Join-Path $script:testRoot 'standalone'
        New-Item -ItemType Directory -Path $child | Out-Null
        Set-Content -LiteralPath (Join-Path $child 'main.tf') -Value 'resource "null_resource" "example" {}'

        $context = Get-AvmModuleContext -Path $child

        $context.Ecosystem | Should -Be 'terraform'
        $context.Root | Should -Be $child
    }

    It 'honours a same-root override before source detection' {
        New-Item -ItemType Directory -Path (Join-Path $script:testRoot '.avm') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:testRoot '.avm' 'context.psd1') -Value @'
@{
    Ecosystem = 'bicep'
    Kind = 'bicep-monorepo'
    Scope = 'res'
    Owner = '@Azure/avm-core'
}
'@
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.tf') -Value 'resource "null_resource" "example" {}'

        $context = Get-AvmModuleContext -Path $script:testRoot

        $context.Kind | Should -Be 'bicep-monorepo'
        $context.Root | Should -Be $script:testRoot
        $context.Scope | Should -Be 'res'
        $context.Owner | Should -Be '@Azure/avm-core'
    }

    It 'throws when explicit ecosystem conflicts with the same-root override' {
        New-Item -ItemType Directory -Path (Join-Path $script:testRoot '.avm') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:testRoot '.avm' 'context.psd1') -Value @'
@{
    Ecosystem = 'bicep'
    Kind = 'bicep-module'
}
'@

        { Get-AvmModuleContext -Path $script:testRoot -Ecosystem terraform } |
            Should -Throw -ExpectedMessage '*conflicts*'
    }

    It 'throws when automatic detection finds direct Terraform and Bicep source' {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.tf') -Value 'resource "null_resource" "example" {}'
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.bicep') -Value 'param name string'

        { Get-AvmModuleContext -Path $script:testRoot } |
            Should -Throw -ExpectedMessage '*Both Terraform and Bicep*'
    }

    It 'selects Terraform from a mixed-source root when explicitly requested' {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'terraform.tf') -Value 'terraform {}'
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.bicep') -Value 'param name string'

        $context = Get-AvmModuleContext -Path $script:testRoot -Ecosystem terraform

        $context.Kind | Should -Be 'terraform-module-repo'
        $context.Ecosystem | Should -Be 'terraform'
    }

    It 'selects Bicep from a mixed-source root when explicitly requested' {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.tf') -Value 'resource "null_resource" "example" {}'
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.bicep') -Value 'param name string'

        $context = Get-AvmModuleContext -Path $script:testRoot -Ecosystem bicep

        $context.Kind | Should -Be 'bicep-module'
        $context.Ecosystem | Should -Be 'bicep'
    }

    It 'requires matching direct Terraform source for an explicit selection' {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.bicep') -Value 'param name string'

        { Get-AvmModuleContext -Path $script:testRoot -Ecosystem terraform } |
            Should -Throw -ExpectedMessage '*no direct *.tf*'
    }

    It 'requires matching Bicep source for an explicit selection' {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'main.tf') -Value 'resource "null_resource" "example" {}'

        { Get-AvmModuleContext -Path $script:testRoot -Ecosystem bicep } |
            Should -Throw -ExpectedMessage '*no direct *.bicep*'
    }

    It 'rejects any depth below a structural folder: <RelativePath>' -ForEach @(
        @{ RelativePath = 'examples' }
        @{ RelativePath = 'examples/default' }
        @{ RelativePath = 'examples/default/nested/deep/module' }
        @{ RelativePath = 'modules' }
        @{ RelativePath = 'modules/foo' }
        @{ RelativePath = 'modules/foo/nested/deep/module' }
        @{ RelativePath = 'tests' }
        @{ RelativePath = 'tests/unit' }
        @{ RelativePath = 'tests/unit/fixtures/nested/deep' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'terraform.tf') -Value 'terraform {}'
        $nested = Join-Path $script:testRoot $RelativePath
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $nested 'main.tf') -Value 'resource "null_resource" "example" {}'

        { Get-AvmModuleContext -Path $nested -Ecosystem terraform } |
            Should -Throw -ExpectedMessage '*reserved*module root*'
    }

    It 'rejects any depth below an administrative folder: <RelativePath>' -ForEach @(
        @{ RelativePath = '.agents' }
        @{ RelativePath = '.agents/skills' }
        @{ RelativePath = '.agents/skills/context/deep' }
        @{ RelativePath = '.avm' }
        @{ RelativePath = '.avm/cache' }
        @{ RelativePath = '.avm/cache/context/deep' }
        @{ RelativePath = '.git' }
        @{ RelativePath = '.git/hooks' }
        @{ RelativePath = '.git/modules/foo/objects/deep' }
        @{ RelativePath = '.github' }
        @{ RelativePath = '.github/workflows' }
        @{ RelativePath = '.github/actions/context/deep' }
        @{ RelativePath = '.terraform' }
        @{ RelativePath = '.terraform/providers' }
        @{ RelativePath = '.terraform/providers/registry/example/deep' }
        @{ RelativePath = '.vscode' }
        @{ RelativePath = '.vscode/settings' }
        @{ RelativePath = '.vscode/settings/context/deep' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:testRoot 'terraform.tf') -Value 'terraform {}'
        $nested = Join-Path $script:testRoot $RelativePath
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $nested 'main.tf') -Value 'resource "null_resource" "example" {}'

        { Get-AvmModuleContext -Path $nested -Ecosystem terraform } |
            Should -Throw -ExpectedMessage '*reserved*module root*'
    }

    It 'rejects a standalone module when a higher ancestor has a reserved name' {
        $genericAncestor = Join-Path $script:testRoot 'examples'
        $moduleRoot = Join-Path $genericAncestor 'checkout' 'standalone-module'
        New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $moduleRoot 'main.tf') -Value 'resource "null_resource" "example" {}'

        { Get-AvmModuleContext -Path $moduleRoot } |
            Should -Throw -ExpectedMessage '*reserved context folder*full path*'
    }

    It 'throws a typed context exception when no same-root source or override exists' {
        try {
            Get-AvmModuleContext -Path $script:testRoot
            throw 'Expected context resolution to fail.'
        }
        catch {
            $_.Exception.GetType().Name | Should -Be 'AvmContextException'
            $_.Exception.Message | Should -BeLike '*must run from the module root*'
        }
    }

    It 'throws a context exception when the path does not exist' {
        { Get-AvmModuleContext -Path (Join-Path $script:testRoot 'missing') } |
            Should -Throw -ExpectedMessage '*Path does not exist*'
    }
}
