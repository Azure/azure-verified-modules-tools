#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    function script:New-BicepMonorepo {
        param([Parameter(Mandatory)] [string] $Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'bicepconfig.json') -Value '{}' -NoNewline
        foreach ($scope in @('res', 'ptn', 'utl')) {
            New-Item -ItemType Directory -Path (Join-Path (Join-Path $Root 'avm') $scope) -Force | Out-Null
        }
    }

    function script:New-BicepModule {
        param([Parameter(Mandatory)] [string] $Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'main.bicep') -Value '// stub' -NoNewline
        Set-Content -LiteralPath (Join-Path $Root 'version.json') -Value '{"version":"0.1"}' -NoNewline
    }

    function script:New-TerraformRepo {
        param([Parameter(Mandatory)] [string] $Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'terraform.tf') -Value '# stub' -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $Root 'examples') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Root 'tests') -Force | Out-Null
    }

    function script:New-TerraformModulePath {
        param([Parameter(Mandatory)] [string] $Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'main.tf') -Value '# stub' -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $Root 'tests') -Force | Out-Null
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmModuleContext' {
    It 'identifies a bicep monorepo at the root' {
        $root = Join-Path $TestDrive 'bm-1'
        script:New-BicepMonorepo -Root $root
        $ctx = Get-AvmModuleContext -Path $root
        $ctx.Kind | Should -Be 'bicep-monorepo'
        $ctx.Ecosystem | Should -Be 'bicep'
        $ctx.Scope | Should -BeNullOrEmpty
    }

    It 'identifies a bicep module path standalone' {
        $root = Join-Path $TestDrive 'bm-2'
        script:New-BicepModule -Root $root
        $ctx = Get-AvmModuleContext -Path $root
        $ctx.Kind | Should -Be 'bicep-module'
        $ctx.Ecosystem | Should -Be 'bicep'
        $ctx.Scope | Should -BeNullOrEmpty
    }

    It 'identifies a bicep module inside a monorepo and infers Scope from avm/res' {
        $repo = Join-Path $TestDrive 'bm-3'
        script:New-BicepMonorepo -Root $repo
        $modPath = Join-Path (Join-Path (Join-Path $repo 'avm') 'res') 'storage-account'
        script:New-BicepModule -Root $modPath
        $ctx = Get-AvmModuleContext -Path $modPath
        $ctx.Kind | Should -Be 'bicep-module'
        $ctx.Scope | Should -Be 'res'
    }

    It 'identifies a terraform module repo at the root' {
        $root = Join-Path $TestDrive 'tf-1'
        script:New-TerraformRepo -Root $root
        $ctx = Get-AvmModuleContext -Path $root
        $ctx.Kind | Should -Be 'terraform-module-repo'
        $ctx.Ecosystem | Should -Be 'terraform'
    }

    It 'identifies a terraform module path (any *.tf + tests/)' {
        $root = Join-Path $TestDrive 'tf-2'
        script:New-TerraformModulePath -Root $root
        $ctx = Get-AvmModuleContext -Path $root
        $ctx.Kind | Should -Be 'terraform-module-path'
        $ctx.Ecosystem | Should -Be 'terraform'
    }

    It 'walks up from a nested subdirectory to find the module root' {
        $root = Join-Path $TestDrive 'tf-3'
        script:New-TerraformModulePath -Root $root
        $sub = Join-Path (Join-Path $root 'examples') 'deep'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        $ctx = Get-AvmModuleContext -Path $sub
        $ctx.Root | Should -Be (Resolve-Path -LiteralPath $root).ProviderPath
    }

    It 'throws AvmContextException when no context can be found' {
        $root = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $err = $null
        try { Get-AvmModuleContext -Path $root } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmContextException'
        $err.Code | Should -Be 'AVM1030'
    }

    It 'throws AvmContextException for a non-existent path' {
        $err = $null
        try { Get-AvmModuleContext -Path (Join-Path $TestDrive 'no-such-dir-12345') } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmContextException'
    }

    It 'emits a JSON document with --json' {
        $root = Join-Path $TestDrive 'bm-json'
        script:New-BicepModule -Root $root
        $json = Get-AvmModuleContext -Path $root -Json
        $obj = $json | ConvertFrom-Json
        $obj.Kind | Should -Be 'bicep-module'
        $obj.Ecosystem | Should -Be 'bicep'
    }
}

Describe 'avm context dispatcher route' {
    It 'routes "avm context PATH" to Get-AvmModuleContext' {
        $root = Join-Path $TestDrive 'bm-route'
        script:New-BicepModule -Root $root
        $ctx = avm context $root
        $ctx.Kind | Should -Be 'bicep-module'
    }
}

Describe 'Get-AvmModuleContext -Ecosystem override' {
    It 'honours -Ecosystem bicep when only bicep signatures exist' {
        $root = Join-Path $TestDrive 'eco-bicep'
        script:New-BicepModule -Root $root
        $ctx = Get-AvmModuleContext -Path $root -Ecosystem 'bicep'
        $ctx.Kind | Should -Be 'bicep-module'
    }

    It 'filters out the other ecosystem and throws when none remain' {
        # Bicep module on disk but caller demands terraform - should fail.
        $root = Join-Path $TestDrive 'eco-conflict'
        script:New-BicepModule -Root $root
        $err = $null
        try { Get-AvmModuleContext -Path $root -Ecosystem 'terraform' } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmContextException'
        $err.Message | Should -Match "Ecosystem='terraform'"
    }

    It 'auto is the default and discovers either ecosystem' {
        $root = Join-Path $TestDrive 'eco-auto'
        script:New-TerraformModulePath -Root $root
        $ctx = Get-AvmModuleContext -Path $root
        $ctx.Ecosystem | Should -Be 'terraform'
    }
}

Describe 'Get-AvmModuleContext .avm/context.psd1 override' {
    It 'uses an explicit override file and ignores heuristics' {
        # Place a Bicep module on disk but declare it as a terraform module
        # via the override file. The override should win.
        $root = Join-Path $TestDrive 'override-1'
        script:New-BicepModule -Root $root
        New-Item -ItemType Directory -Path (Join-Path $root '.avm') -Force | Out-Null
        $payload = "@{ Ecosystem = 'terraform'; Kind = 'terraform-module-path'; Owner = '@Azure/avm-core' }"
        Set-Content -LiteralPath (Join-Path (Join-Path $root '.avm') 'context.psd1') -Value $payload

        $ctx = Get-AvmModuleContext -Path $root
        $ctx.Ecosystem | Should -Be 'terraform'
        $ctx.Kind | Should -Be 'terraform-module-path'
        $ctx.Owner | Should -Be '@Azure/avm-core'
    }

    It 'walks up to find the override file from a nested subdirectory' {
        $root = Join-Path $TestDrive 'override-2'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root '.avm') -Force | Out-Null
        $payload = "@{ Ecosystem = 'bicep'; Kind = 'bicep-monorepo' }"
        Set-Content -LiteralPath (Join-Path (Join-Path $root '.avm') 'context.psd1') -Value $payload
        $sub = Join-Path (Join-Path $root 'avm') 'res'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null

        $ctx = Get-AvmModuleContext -Path $sub
        $ctx.Kind | Should -Be 'bicep-monorepo'
        $ctx.Root | Should -Be (Resolve-Path -LiteralPath $root).ProviderPath
    }

    It 'throws AvmConfigurationException for an invalid Ecosystem value in the override' {
        $root = Join-Path $TestDrive 'override-bad'
        New-Item -ItemType Directory -Path (Join-Path $root '.avm') -Force | Out-Null
        $payload = "@{ Ecosystem = 'pulumi'; Kind = 'bicep-module' }"
        Set-Content -LiteralPath (Join-Path (Join-Path $root '.avm') 'context.psd1') -Value $payload

        $err = $null
        try { Get-AvmModuleContext -Path $root } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message | Should -Match "Ecosystem 'pulumi'"
    }

    It 'throws AvmContextException when -Ecosystem disagrees with the override file' {
        $root = Join-Path $TestDrive 'override-conflict'
        New-Item -ItemType Directory -Path (Join-Path $root '.avm') -Force | Out-Null
        $payload = "@{ Ecosystem = 'bicep'; Kind = 'bicep-module' }"
        Set-Content -LiteralPath (Join-Path (Join-Path $root '.avm') 'context.psd1') -Value $payload

        $err = $null
        try { Get-AvmModuleContext -Path $root -Ecosystem 'terraform' } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmContextException'
    }
}
