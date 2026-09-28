#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring')
    $script:fixtureRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'fixtures' 'bicep-docs')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    function New-BicepDocsFixture {
        param([Parameter(Mandatory)][string] $Name)

        $root = Join-Path $TestDrive $Name
        $module = Join-Path $root 'avm' 'res' 'storage' 'storage-account'
        $null = New-Item -ItemType Directory -Path $module -Force
        Copy-Item -Path (Join-Path $script:fixtureRoot '*') -Destination $module -Recurse
        $template = Join-Path $root 'docs' 'templates' 'avm-readme-v1.scriban'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $template -Parent) -Force
        Copy-Item -LiteralPath (Join-Path $script:moduleRoot 'Resources' 'bicep' 'avm-readme-v1.scriban') `
            -Destination $template
        $config = @'
{
  "documentation": {
    "template": { "file": "docs/templates/avm-readme-v1.scriban" },
    "examples": {
      "reassignments": [
        { "from": { "include": ["**/rg-scope.*/**"] }, "to": "rg-scope" }
      ]
    }
  }
}
'@
        [System.IO.File]::WriteAllText(
            (Join-Path $root 'bicepconfig.json'), $config, [System.Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ Root = $root; Module = $module; Template = $template }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep docs source rendering' -Tag Component {
    It 'renders root and child once, writes only changed README bytes, and checks drift without writing' {
        $fixture = New-BicepDocsFixture -Name 'fresh'
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            $script:customPaths = [System.Collections.Generic.List[string]]::new()
            $script:references = [System.Collections.Generic.List[string]]::new()
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                $script:customPaths.Add($ArgumentList[5])
                $data = [System.IO.File]::ReadAllText($ArgumentList[5]) | ConvertFrom-Json -AsHashtable
                $script:references.Add($data.moduleReference)
                $body = if ($WorkingDirectory -match 'child$') { "# Child`n" } else { "# Root`n" }
                [pscustomobject]@{ ExitCode = 0; StdOut = $body; StdErr = '' }
            }

            $preview = Invoke-AvmDocs -Path $F.Root -CheckDrift `
                -IncludeRenderedContent -SkipModuleVersionCheck
            $preview.Status | Should -BeExactly 'fail'
            $preview.FilesSelected | Should -Be 2
            $preview.FilesProcessed | Should -Be 2
            $preview.GeneratedReadmes.Count | Should -Be 2
            $preview.GeneratedReadmes[0].Content | Should -BeExactly "# Root`n"
            @($preview.Issues | Where-Object { $_.Code -eq 'avm.bicep.docs-missing' }).Count |
                Should -Be 2
            Test-Path -LiteralPath (Join-Path $F.Module 'README.md') | Should -BeFalse

            $written = Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck
            $written.Status | Should -BeExactly 'pass'
            $written.Changed.Count | Should -Be 2
            $written.FilesProcessed | Should -Be 2
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'README.md')) |
                Should -BeExactly "# Root`n"
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'child' 'README.md')) |
                Should -BeExactly "# Child`n"
            $before = [System.IO.File]::GetLastWriteTimeUtc((Join-Path $F.Module 'README.md'))

            $clean = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $clean.Status | Should -BeExactly 'pass'
            $clean.Issues.Count | Should -Be 0
            $clean.Changed.Count | Should -Be 0
            [System.IO.File]::GetLastWriteTimeUtc((Join-Path $F.Module 'README.md')) |
                Should -Be $before
            $script:references | Should -Contain 'avm/res/storage/storage-account'
            $script:references | Should -Contain 'avm/res/storage/storage-account/child'
            foreach ($path in $script:customPaths) {
                Test-Path -LiteralPath $path | Should -BeFalse
            }
        }
    }

    It 'validates all modules first and preserves their READMEs on a compiler error' {
        $fixture = New-BicepDocsFixture -Name 'compiler-error'
        $readme = Join-Path $fixture.Module 'README.md'
        [System.IO.File]::WriteAllText($readme, "Original`n")
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                if ($WorkingDirectory -match 'child$') {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'BCP426: compile error' }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = "# New root`n"; StdErr = '' }
            }
            { Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck } |
                Should -Throw '*BCP426: compile error*'
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'README.md')) |
                Should -BeExactly "Original`n"
            Test-Path -LiteralPath (Join-Path $F.Module 'child' 'README.md') | Should -BeFalse
        }
    }

    It 'continues through compile failures in drift mode and returns each successful render' {
        $fixture = New-BicepDocsFixture -Name 'drift-compile-error'
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                if ($WorkingDirectory -match 'child$') {
                    return [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'BCP426: child failure' }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = "# Parent`n"; StdErr = '' }
            }

            $result = Invoke-AvmDocs -Path $F.Root -CheckDrift `
                -IncludeRenderedContent -SkipModuleVersionCheck
            $result.Status | Should -BeExactly 'fail'
            $result.FilesSelected | Should -Be 2
            $result.FilesProcessed | Should -Be 1
            $result.GeneratedReadmes.Count | Should -Be 1
            $result.GeneratedReadmes[0].Path | Should -BeExactly 'avm/res/storage/storage-account/README.md'
            $result.GeneratedReadmes[0].Content | Should -BeExactly "# Parent`n"
            @($result.Issues | Where-Object { $_.Code -eq 'avm.bicep.docs-render-failed' }).Count |
                Should -Be 1
            $result.Issues[1].Message | Should -Match 'BCP426: child failure'
            Test-Path -LiteralPath (Join-Path $F.Module 'README.md') | Should -BeFalse
        }
    }

    It 'does not publish an ambiguous compiled role list as successful documentation' {
        $fixture = New-BicepDocsFixture -Name 'ambiguous-role-map'
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = "__AVM_DOCS_AMBIGUOUS_ROLES__:a.roleAssignments`n"
                    StdErr   = ''
                }
            }
            $result = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $result.Status | Should -BeExactly 'fail'
            $result.FilesSelected | Should -Be 2
            $result.FilesProcessed | Should -Be 0
            @($result.Issues | Where-Object Code -EQ 'avm.bicep.docs-render-failed').Count |
                Should -Be 2
            $result.Issues[0].Message | Should -Match 'conflicting compiled role names'
            { Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck } |
                Should -Throw '*conflicting compiled role names*'
            Test-Path -LiteralPath (Join-Path $F.Module 'README.md') | Should -BeFalse
        }
    }

    It 'rejects discriminator cases missing from the native Bicep docs model' {
        $fixture = New-BicepDocsFixture -Name 'missing-discriminator-variant'
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = "__AVM_DOCS_MISSING_VARIANT__:criteria`n"
                    StdErr   = ''
                }
            }
            $result = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $result.Status | Should -BeExactly 'fail'
            $result.FilesProcessed | Should -Be 0
            @($result.Issues | Where-Object Code -EQ 'avm.bicep.docs-render-failed').Count |
                Should -Be 2
            $result.Issues[0].Message | Should -Match 'discriminator variants differ'
            { Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck } |
                Should -Throw '*discriminator variants differ*'
            Test-Path -LiteralPath (Join-Path $F.Module 'README.md') | Should -BeFalse
        }
    }

    It 'builds compiled JSON when absent and includes transitive resource types' {
        $fixture = New-BicepDocsFixture -Name 'compiled-fallback'
        Remove-Item -LiteralPath (Join-Path $fixture.Module 'main.json')
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            $script:compiledTypes = @()
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'build') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdErr   = ''
                        StdOut  = '{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#","contentVersion":"1.0.0.0","resources":[{"type":"Microsoft.Resources/deployments","apiVersion":"2025-04-01","properties":{"template":{"resources":[{"type":"Microsoft.Authorization/locks","apiVersion":"2020-05-01"}]}}}]}'
                    }
                }
                $data = [System.IO.File]::ReadAllText($ArgumentList[5]) | ConvertFrom-Json -AsHashtable
                if ($WorkingDirectory -notmatch 'child$') {
                    $script:compiledTypes = @($data.resourceTypes | ConvertFrom-Json)
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = "# Rendered`n"; StdErr = '' }
            }
            $result = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $result.FilesProcessed | Should -Be 2
            $script:compiledTypes[0].Type | Should -BeExactly 'Microsoft.Authorization/locks'
            $script:compiledTypes[0].ApiVersion | Should -BeExactly '2020-05-01'
            Should -Invoke Invoke-AvmProcess -Exactly 3
        }
    }

    It 'reports a compiled-source failure per module without discarding other rendered content' {
        $fixture = New-BicepDocsFixture -Name 'build-error'
        Remove-Item -LiteralPath (Join-Path $fixture.Module 'child' 'main.json')
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'build') {
                    return [pscustomobject]@{
                        ExitCode = 1; StdOut = ''; StdErr = 'BCP426: invalid source'
                    }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = "# Root`n"; StdErr = '' }
            }
            $result = Invoke-AvmDocs -Path $F.Root -CheckDrift `
                -IncludeRenderedContent -SkipModuleVersionCheck
            $result.FilesSelected | Should -Be 2
            $result.FilesProcessed | Should -Be 1
            $result.GeneratedReadmes.Count | Should -Be 1
            @($result.Issues | Where-Object { $_.Code -eq 'avm.bicep.docs-render-failed' }).Count |
                Should -Be 1
            ($result.Issues | Where-Object { $_.Code -eq 'avm.bicep.docs-render-failed' }).Message |
                Should -Match 'BCP426: invalid source'
        }
    }

    It 'does not overwrite authored Notes without a sidecar or change sources with -WhatIf' {
        $fixture = New-BicepDocsFixture -Name 'authored-notes'
        $readme = Join-Path $fixture.Module 'README.md'
        [System.IO.File]::WriteAllText($readme, "# Authored`n## Notes`n`nAn important note.`n")
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = "# Generated`n"; StdErr = '' }
            }
            { Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck } |
                Should -Throw '*avm docs export-notes*'
            Should -Invoke Invoke-AvmProcess -Exactly 0
            $sidecar = Join-Path $F.Module 'README.notes.md'
            [System.IO.File]::WriteAllText($sidecar, "`nAn important note.`n")
            $preview = Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck -WhatIf
            $preview.Status | Should -BeExactly 'skipped'
            $preview.Changed.Count | Should -Be 0
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'README.md')) |
                Should -BeExactly "# Authored`n## Notes`n`nAn important note.`n"
        }
    }

    It 'finds nested source-backed modules and explicitly reports source-less READMEs' {
        $fixture = New-BicepDocsFixture -Name 'all-module-scopes'
        $nested = Join-Path $fixture.Root 'avm' 'ptn' 'ai-ml' 'ai-foundry' 'modules' 'project'
        $static = Join-Path $fixture.Root 'avm' 'ptn' 'aca-lza' 'hosting-environment' 'modules' 'spoke'
        $null = New-Item -ItemType Directory -Path $nested, $static -Force
        [System.IO.File]::WriteAllText((Join-Path $nested 'main.bicep'), "metadata name = 'Project'`n")
        Copy-Item -LiteralPath (Join-Path $fixture.Module 'child' 'main.json') `
            -Destination (Join-Path $nested 'main.json')
        [System.IO.File]::WriteAllText((Join-Path $static 'README.md'), "# Walkthrough`n")
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = "# Rendered`n"; StdErr = '' }
            }
            $result = Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck
            $result.Status | Should -BeExactly 'fail'
            $result.FilesProcessed | Should -Be 3
            $result.NotRendered | Should -Contain 'avm/ptn/aca-lza/hosting-environment/modules/spoke/README.md'
            $result.Issues[0].Code | Should -BeExactly 'avm.bicep.docs-no-source'
            Test-Path -LiteralPath (Join-Path $F.Module 'README.md') | Should -BeFalse
            [System.IO.File]::ReadAllText(
                (Join-Path $F.Root 'avm' 'ptn' 'aca-lza' 'hosting-environment' 'modules' 'spoke' 'README.md')) |
                Should -BeExactly "# Walkthrough`n"
        }
    }

    It 'uses the entire nested pattern module path in its README title' {
        $fixture = New-BicepDocsFixture -Name 'nested-pattern-header'
        $nested = Join-Path $fixture.Root 'avm' 'ptn' 'ai-ml' 'ai-foundry' 'modules' 'project'
        $null = New-Item -ItemType Directory -Path $nested -Force
        Copy-Item -LiteralPath (Join-Path $fixture.Module 'main.bicep') `
            -Destination (Join-Path $nested 'main.bicep')
        Copy-Item -LiteralPath (Join-Path $fixture.Module 'main.json') `
            -Destination (Join-Path $nested 'main.json')
        $values = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture; N = $nested } {
            param($F, $N)
            Get-AvmBicepDocsCustomValue -ModulePath $N `
                -RepositoryRoot $F.Root -ToolPath 'mock-bicep'
        }
        $values.headerType | Should -BeExactly 'AiMl/AiFoundryModulesProject'
        $values.moduleReference | Should -BeExactly 'avm/ptn/ai-ml/ai-foundry/modules/project'
    }

    It 'selects the resource type matching the module slug over stale canonical metadata' {
        $fixture = New-BicepDocsFixture -Name 'resource-header'
        $metadataPath = Join-Path $fixture.Module 'metadata.json'
        $compiledPath = Join-Path $fixture.Module 'main.json'
        $compiled = [System.IO.File]::ReadAllText($compiledPath) | ConvertFrom-Json -AsHashtable
        $compiled.resources += @{
            type       = 'Microsoft.Authorization/roleAssignments'
            apiVersion = '2022-04-01'
        }
        [System.IO.File]::WriteAllText(
            $compiledPath, (ConvertTo-Json -InputObject $compiled -Depth 99),
            [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText(
            $metadataPath, '{"canonicalType":"Microsoft.Authorization/roleAssignments"}',
            [System.Text.UTF8Encoding]::new($false))
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Get-AvmBicepDocsCustomValue -ModulePath $F.Module `
                -RepositoryRoot $F.Root -ToolPath 'mock-bicep'
        }
        $result.headerType | Should -BeExactly 'Microsoft.Storage/storageAccounts'

        [System.IO.File]::WriteAllText(
            $metadataPath, '{"canonicalType":"Microsoft.Storage/storageaccounts"}',
            [System.Text.UTF8Encoding]::new($false))
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Get-AvmBicepDocsCustomValue -ModulePath $F.Module `
                -RepositoryRoot $F.Root -ToolPath 'mock-bicep'
        }
        $result.headerType | Should -BeExactly 'Microsoft.Storage/storageAccounts'

        $compiled.resources = @()
        [System.IO.File]::WriteAllText(
            $compiledPath, (ConvertTo-Json -InputObject $compiled -Depth 99),
            [System.Text.UTF8Encoding]::new($false))
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Get-AvmBicepDocsCustomValue -ModulePath $F.Module `
                -RepositoryRoot $F.Root -ToolPath 'mock-bicep'
        }
        $result.headerType | Should -BeExactly 'Microsoft.Storage/storageaccounts'
    }

    It 'requires an unmodified versioned template relative to the nearest config' {
        $fixture = New-BicepDocsFixture -Name 'template-guard'
        [System.IO.File]::AppendAllText($fixture.Template, "`nunauthorized edit")
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess { throw 'should not run with mismatched template' }
            { Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck } |
                Should -Throw '*differs from the packaged*'
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }

    It 'includes remote imports across local sources and external local module references' {
        $fixture = New-BicepDocsFixture -Name 'transitive-references'
        $external = Join-Path $fixture.Root 'avm' 'res' 'key-vault' 'vault'
        $imported = Join-Path $fixture.Root 'avm' 'res' 'dev-center' 'project' 'pool'
        $nested = Join-Path $fixture.Module 'modules'
        $null = New-Item -ItemType Directory -Path $external, $imported, $nested -Force
        [System.IO.File]::AppendAllText((Join-Path $fixture.Module 'main.bicep'), @'

import { lockType } from 'br/public:avm/utl/types/avm-common-types:0.6.0'
import { poolType } from '../../dev-center/project/pool/main.bicep'
module nested 'modules/dependency.bicep' = {}
module vault '../../key-vault/vault/main.bicep' = {}
'@)
        [System.IO.File]::WriteAllText((Join-Path $nested 'dependency.bicep'), @'
import { lockType } from 'br/public:avm/utl/types/avm-common-types:0.4.1'
'@)
        [System.IO.File]::WriteAllText((Join-Path $external 'main.bicep'), @'
import { lockType } from 'br/public:avm/utl/types/avm-common-types:0.6.0'
'@)
        [System.IO.File]::WriteAllText((Join-Path $imported 'main.bicep'), @'
module schedule 'schedule/main.bicep' = {}
import { lockType } from 'br/public:avm/utl/types/avm-common-types:0.3.0'
'@)
        $references = @(InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
                param($F)
                Get-AvmBicepDocsReference -ModulePath $F.Module -RepositoryRoot $F.Root
            })
        @($references.Path) | Should -Be @(
            'avm/res/key-vault/vault',
            'br/public:avm/utl/types/avm-common-types:0.4.1',
            'br/public:avm/utl/types/avm-common-types:0.6.0'
        )
        @($references.Kind) | Should -Be @('Local', 'Remote', 'Remote')
    }

    It 'extracts source-derived test values without reading an existing README' {
        $fixture = New-BicepDocsFixture -Name 'example-sources'
        $child = Join-Path $fixture.Module 'rg-scope'
        $null = New-Item -ItemType Directory -Path $child -Force
        $examples = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture; Child = $child } {
            param($F, $Child)
            Get-AvmBicepDocsExample -ModulePath $Child -RepositoryRoot $F.Root `
                -RequiredParameters @('name')
        }
        $example = $examples['../tests/e2e/rg-scope.minimal/main.test.bicep']
        $example.IsModule | Should -BeTrue
        $example.Parameters.name.value | Should -BeExactly 'avmdocs12345'
        $example.BicepParameters | Should -BeExactly "    name: 'avmdocs12345'"
        $example.JsonParameters | Should -Match '"contentVersion": "1.0.0.0"'
        $example.BicepParameterFile | Should -BeExactly "param name = 'avmdocs12345'"
        Test-Path -LiteralPath (Join-Path $fixture.Module 'README.md') | Should -BeFalse
    }

    It 'orders multi-scope child links for the parent usage section' {
        $fixture = New-BicepDocsFixture -Name 'multi-scope-parent'
        foreach ($name in @('sub-scope', 'mg-scope', 'rg-scope')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $fixture.Module $name) -Force
        }
        $values = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Get-AvmBicepDocsCustomValue -ModulePath $F.Module `
                -RepositoryRoot $F.Root -ToolPath 'mock-bicep'
        }
        @($values.scopeChildren | ConvertFrom-Json) | Should -Be @(
            'mg-scope', 'rg-scope', 'sub-scope'
        )
    }

    It 'enumerates compiled keys parameters and outputs without losing other entries' {
        $fixture = New-BicepDocsFixture -Name 'shadowed-compiled-keys'
        $path = Join-Path $fixture.Module 'main.json'
        $compiled = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
        $compiled.parameters['keys'] = @{ type = 'array' }
        $compiled.outputs = @{
            keys    = @{ value = 'first' }
            regular = @{ value = 'second' }
        }
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $compiled -Depth 99))
        $values = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Get-AvmBicepDocsCustomValue -ModulePath $F.Module `
                -RepositoryRoot $F.Root -ToolPath 'mock-bicep'
        }
        $parameters = $values.compiledParameters | ConvertFrom-Json -AsHashtable
        $parameters.ContainsKey('keys') | Should -BeTrue
        $parameters.ContainsKey('name') | Should -BeTrue
        $values.typelessOutputs | Should -Match '\|keys\|'
        $values.typelessOutputs | Should -Match '\|regular\|'
    }

    It 'preserves compiled trailing description newlines omitted by the native model' {
        $fixture = New-BicepDocsFixture -Name 'multiline-description'
        $path = Join-Path $fixture.Module 'main.json'
        $compiled = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
        $compiled.metadata = @{ description = "A multiline description.`n`n" }
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $compiled -Depth 99))
        $values = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Get-AvmBicepDocsCustomValue -ModulePath $F.Module `
                -RepositoryRoot $F.Root -ToolPath 'mock-bicep'
        }
        $values.descriptionSuffix | Should -BeExactly "`n`n"
    }

    It 'passes root and nested compiled role names into the documentation template' {
        $fixture = New-BicepDocsFixture -Name 'built-in-role-names'
        $path = Join-Path $fixture.Module 'main.json'
        $compiled = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
        $compiled.variables = @{ builtInRoleNames = [ordered]@{ Contributor = 'root-id' } }
        $compiled.resources = @{
            storage_keys = @{
                type       = 'Microsoft.Resources/deployments'
                apiVersion = '2025-04-01'
                properties = @{
                    template = @{
                        variables = @{ builtInRoleNames = [ordered]@{ Reader = 'child-id' } }
                    }
                }
            }
        }
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $compiled -Depth 99))
        $values = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Get-AvmBicepDocsCustomValue -ModulePath $F.Module `
                -RepositoryRoot $F.Root -ToolPath 'mock-bicep'
        }
        $roles = $values.roleNames | ConvertFrom-Json -AsHashtable
        @($roles | Where-Object Identifier -EQ '')[0].Names | Should -Be @('Contributor')
        @($roles | Where-Object Identifier -EQ 'storage_keys')[0].Names | Should -Be @('Reader')
    }

    It 'does not follow a source reference outside the repository' {
        $fixture = New-BicepDocsFixture -Name 'invalid-reference'
        $sourcePath = Join-Path $fixture.Module 'main.bicep'
        [System.IO.File]::AppendAllText($sourcePath,
            "`nmodule escape '../../../../../outside/main.bicep' = {}`n")
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
                param($F)
                Get-AvmBicepDocsReference -ModulePath $F.Module -RepositoryRoot $F.Root
            }
        } | Should -Throw '*outside the repository*'
        $source = [System.IO.File]::ReadAllText($sourcePath).Replace(
            "module escape '../../../../../outside/main.bicep' = {}",
            "import { escapedType } from '../../../../../outside/main.bicep'")
        [System.IO.File]::WriteAllText($sourcePath, $source)
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
                param($F)
                Get-AvmBicepDocsReference -ModulePath $F.Module -RepositoryRoot $F.Root
            }
        } | Should -Throw '*outside the repository*'
    }

    It 'requires drift mode when returning rendered content' {
        $fixture = New-BicepDocsFixture -Name 'rendered-guard'
        { Invoke-AvmDocs -Path $fixture.Root -IncludeRenderedContent -SkipModuleVersionCheck } |
            Should -Throw '*requires -CheckDrift*'
    }
}
