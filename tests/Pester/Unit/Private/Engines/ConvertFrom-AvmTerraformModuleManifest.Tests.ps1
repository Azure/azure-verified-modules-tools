#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-AvmTerraformModuleManifest' {
    It 'resolves direct and transitive directories and deduplicates repeated local module calls' {
        InModuleScope 'Avm.Authoring' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) 'manifest-unit'
            $example = Join-Path $root 'examples' 'default'
            $json = @'
{"Modules":[
  {"Key":"subject.nested","Dir":"../../modules/nested"},
  {"Key":"","Dir":"."},
  {"Key":"subject","Dir":"../.."},
  {"Key":"another","Dir":"../../"}
]}
'@
            $directories = @(ConvertFrom-AvmTerraformModuleManifest -Payload $json -WorkingDirectory $example)
            $directories.Count | Should -Be 2
            $directories | Should -Contain $root
            $directories | Should -Contain (Join-Path $root 'modules' 'nested')
            $directories | Should -Not -Contain $example
        }
    }

    It 'excludes synthetic test-only branches without excluding a real module named test' {
        InModuleScope 'Avm.Authoring' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) 'manifest-unit'
            $json = @'
{"Modules":[
  {"Key":"","Dir":"."},
  {"Key":"test","Dir":"child"},
  {"Key":"test.nested","Dir":"leaf"},
  {"Key":"test.tests\\dependencies.fixture","Dir":"only-test"},
  {"Key":"test.tests\\dependencies.fixture.nested","Dir":"only-test/child"},
  {"Key":"test.root_test.fixture","Dir":"root-test-only"}
]}
'@
            $directories = @(ConvertFrom-AvmTerraformModuleManifest -Payload $json -WorkingDirectory $root)
            $directories.Count | Should -Be 2
            $directories | Should -Contain (Join-Path $root 'child')
            $directories | Should -Contain (Join-Path $root 'leaf')
        }
    }

    It 'requires every parent in the path to be reachable' {
        InModuleScope 'Avm.Authoring' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) 'manifest-unit'
            $json = '{"Modules":[{"Key":"","Dir":"."},{"Key":"absent.child","Dir":"unreachable"},{"Key":"absent.child.leaf","Dir":"also-unreachable"}]}'
            @(ConvertFrom-AvmTerraformModuleManifest -Payload $json -WorkingDirectory $root).Count | Should -Be 0
        }
    }

    It 'excludes test-only keys even when their synthetic parents match real module names' {
        InModuleScope 'Avm.Authoring' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) 'manifest-unit'
            $json = @'
{"Modules":[
  {"Key":"","Dir":"."},
  {"Key":"test","Dir":"child"},
  {"Key":"test.nested","Dir":"leaf"},
  {"Key":"test.nested.fixture","Dir":"test-only"},
  {"Key":"test.nested.fixture.child","Dir":"test-only-child"},
  {"Key":"test.tests\\dependencies.fixture","Dir":"json-test-only"}
]}
'@
            $directories = @(ConvertFrom-AvmTerraformModuleManifest -Payload $json -WorkingDirectory $root `
                    -TestFiles @('nested.tftest.hcl', 'tests/dependencies.tftest.json'))
            $directories.Count | Should -Be 2
            $directories | Should -Contain (Join-Path $root 'child')
            $directories | Should -Contain (Join-Path $root 'leaf')
        }
    }

    It 'preserves case-sensitive directory identities on every platform' {
        InModuleScope 'Avm.Authoring' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) 'manifest-unit'
            $json = '{"Modules":[{"Key":"","Dir":"."},{"Key":"A","Dir":"Module"},{"Key":"a","Dir":"module"}]}'
            $directories = @(ConvertFrom-AvmTerraformModuleManifest -Payload $json -WorkingDirectory $root)
            $directories.Count | Should -Be 2
            $directories[0] | Should -BeExactly (Join-Path $root 'Module')
            $directories[1] | Should -BeExactly (Join-Path $root 'module')
        }
    }

    It 'accepts absolute installed directories' {
        InModuleScope 'Avm.Authoring' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) 'manifest-unit'
            $installed = Join-Path ([System.IO.Path]::GetTempPath()) 'installed-module'
            $json = @{ Modules = @(@{ Key = ''; Dir = '.' }, @{ Key = 'subject'; Dir = $installed }) } |
                ConvertTo-Json -Depth 4 -Compress
            @(ConvertFrom-AvmTerraformModuleManifest -Payload $json -WorkingDirectory $root) |
                Should -Be @($installed)
        }
    }

    It 'returns no child directories for a root-only manifest' {
        InModuleScope 'Avm.Authoring' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) 'manifest-unit'
            @(ConvertFrom-AvmTerraformModuleManifest -Payload '{"Modules":[{"Key":"","Dir":"."}]}' -WorkingDirectory $root).Count |
                Should -Be 0
        }
    }

    It 'rejects an invalid manifest: <Scenario>' -TestCases @(
        @{ Scenario = 'empty JSON'; Payload = '' }
        @{ Scenario = 'invalid JSON'; Payload = '{' }
        @{ Scenario = 'missing module array'; Payload = '{}' }
        @{ Scenario = 'null module array'; Payload = '{"Modules":null}' }
        @{ Scenario = 'non-array modules'; Payload = '{"Modules":{}}' }
        @{ Scenario = 'missing root'; Payload = '{"Modules":[{"Key":"subject","Dir":"child"}]}' }
        @{ Scenario = 'duplicate keys'; Payload = '{"Modules":[{"Key":"","Dir":"."},{"Key":"","Dir":"."}]}' }
        @{ Scenario = 'missing key'; Payload = '{"Modules":[{"Dir":"."}]}' }
        @{ Scenario = 'non-string key'; Payload = '{"Modules":[{"Key":1,"Dir":"."}]}' }
        @{ Scenario = 'missing directory'; Payload = '{"Modules":[{"Key":""}]}' }
        @{ Scenario = 'empty directory'; Payload = '{"Modules":[{"Key":"","Dir":""}]}' }
        @{ Scenario = 'non-string directory'; Payload = '{"Modules":[{"Key":"","Dir":123}]}' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Json = $Payload } {
            param($Json)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) 'manifest-unit'
            { ConvertFrom-AvmTerraformModuleManifest -Payload $Json -WorkingDirectory $root } |
                Should -Throw -ExceptionType ([AvmConfigurationException])
        }
    }
}
