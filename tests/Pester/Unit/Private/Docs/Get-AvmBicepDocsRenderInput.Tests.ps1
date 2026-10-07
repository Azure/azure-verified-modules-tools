#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..')).Path
    Import-Module (Join-Path $root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep docs config-based render inputs' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ('docs source ' + [guid]::NewGuid().ToString('N'))
        $script:module = Join-Path $script:root 'module'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:module 'child') -Force
        [IO.File]::WriteAllText((Join-Path $script:module 'main.bicep'), "param name string`r`n")
        [IO.File]::WriteAllText((Join-Path $script:module 'child' 'main.bicep'), 'param childName string')
        $script:stages = [System.Collections.Generic.Dictionary[string, string]]::new()
    }

    AfterEach {
        foreach ($stage in $script:stages.Values) {
            if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage, $true) }
        }
    }

    It 'uses an explicit validated caller template without staging or unsupported CLI options' {
        InModuleScope Avm.Authoring -Parameters @{ Path = $script:module; Stages = $script:stages } {
            param($Path, $Stages)
            $config = [pscustomobject]@{ UsesPackageTemplate = $false }
            $source = Join-Path $Path 'main.bicep'
            $renderInput = Get-AvmBicepDocsRenderInput -SourcePath $source -Root $Path -Configuration $config -Stages $Stages
            $renderInput.SourcePath | Should -BeExactly $source
            $Stages.Count | Should -Be 0
            Mock Invoke-AvmProcess {
                $ArgumentList | Should -HaveCount 6
                $ArgumentList[0..3] | Should -Be @('docs', 'generate', $script:renderSource, '--stdout')
                $ArgumentList[4] | Should -Be '--custom-template-value-file-path'
                [IO.File]::Exists($ArgumentList[5]) | Should -BeTrue
                $script:valuesFile = $ArgumentList[5]
                [pscustomobject]@{ ExitCode = 0; StdOut = "# README`n"; StdErr = '' }
            }
            $script:renderSource = $source
            $null = Invoke-AvmBicepDocsRender -Values @{ moduleReference = 'avm/res/mock/mock' } `
                -SourcePath $renderInput.SourcePath -WorkingDirectory $renderInput.WorkingDirectory -ToolPath fake-bicep
            [IO.File]::Exists($script:valuesFile) | Should -BeFalse
        }
    }

    It 'stages package defaults without changing caller bytes: <Kind>' -ForEach @(
        @{ Kind = 'no config'; Json = $null }
        @{ Kind = 'compiler config'; Json = '{"analyzers":{"core":{"enabled":true}}}' }
        @{ Kind = 'example config'; Json = '{"documentation":{"examples":{"sources":[{"path":"tests"}],"reassignments":[{"from":{"include":["**/child/**"]},"to":"child"}]}}}' }
    ) {
        if ($null -ne $Json) {
            [IO.File]::WriteAllText((Join-Path $script:root 'bicepconfig.json'), $Json)
        }
        [IO.File]::WriteAllBytes((Join-Path $script:root 'asset.bin'), [byte[]]@(0, 255, 13, 10))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:root '.git')
        [IO.File]::WriteAllText((Join-Path $script:root '.git' 'config'), 'not a documentation input')
        InModuleScope Avm.Authoring -Parameters @{
            Root = $script:root; Path = $script:module; Stages = $script:stages; Json = $Json
        } {
            param($Root, $Path, $Stages, $Json)
            $source = Join-Path $Path 'main.bicep'
            $configuration = Get-AvmBicepDocsConfiguration -ModulePath $Path
            $configuration.UsesPackageTemplate | Should -BeTrue
            $renderInput = Get-AvmBicepDocsRenderInput -SourcePath $source -Root $Root `
                -Configuration $configuration -Stages $Stages
            $Stages.Count | Should -Be 1
            $stage = $Stages[$Root]
            if (-not $IsWindows) {
                [IO.File]::GetUnixFileMode($stage) | Should -Be (
                    [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
            }
            $renderInput.SourcePath | Should -BeExactly (Join-Path $stage 'module' 'main.bicep')
            $renderInput.WorkingDirectory | Should -BeExactly (Join-Path $stage 'module')
            [IO.File]::ReadAllText($renderInput.SourcePath) | Should -BeExactly "param name string`r`n"
            [IO.File]::ReadAllText($source) | Should -BeExactly "param name string`r`n"
            [IO.File]::ReadAllBytes((Join-Path $stage 'asset.bin')) | Should -Be ([byte[]]@(0, 255, 13, 10))
            Test-Path -LiteralPath (Join-Path $stage '.git') | Should -BeFalse
            $stagedConfig = [IO.File]::ReadAllText((Join-Path $stage 'bicepconfig.json')) | ConvertFrom-Json -AsHashtable
            $stagedConfig.documentation.template.file | Should -BeExactly $configuration.TemplatePath
            if ($null -eq $Json) {
                Test-Path -LiteralPath (Join-Path $Root 'bicepconfig.json') | Should -BeFalse
            }
            else {
                [IO.File]::ReadAllText((Join-Path $Root 'bicepconfig.json')) | Should -BeExactly $Json
                $original = $Json | ConvertFrom-Json -AsHashtable
                if ($original.Contains('analyzers')) {
                    $stagedConfig.analyzers.core.enabled | Should -BeTrue
                }
                if ($original.Contains('documentation')) {
                    $stagedConfig.documentation.examples.sources[0].path | Should -Be 'tests'
                    $stagedConfig.documentation.examples.reassignments[0].to | Should -Be 'child'
                }
            }
            $child = Join-Path $Path 'child'
            $childInput = Get-AvmBicepDocsRenderInput -SourcePath (Join-Path $child 'main.bicep') `
                -Root $Root -Configuration $configuration -Stages $Stages
            $Stages.Count | Should -Be 1
            $childInput.SourcePath | Should -BeExactly (Join-Path $stage 'module' 'child' 'main.bicep')
        }
    }

    It 'preserves a scoped module and sibling dependencies beneath an ancestor config' {
        [IO.File]::WriteAllText((Join-Path $script:root 'bicepconfig.json'), '{"experimentalFeaturesEnabled":{"symbolicNameCodegen":true}}')
        [IO.File]::WriteAllText((Join-Path $script:root 'shared.bicep'), 'output value string = ''shared''')
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Path = $script:module; Stages = $script:stages } {
            param($Root, $Path, $Stages)
            $configuration = Get-AvmBicepDocsConfiguration -ModulePath $Path
            $null = Get-AvmBicepDocsRenderInput -SourcePath (Join-Path $Path 'main.bicep') `
                -Root $Path -Configuration $configuration -Stages $Stages
            $Stages.ContainsKey($Root) | Should -BeTrue
            [IO.File]::ReadAllText((Join-Path $Stages[$Root] 'shared.bicep')) |
                Should -BeExactly 'output value string = ''shared'''
        }
    }

    It 'preserves literal configuration strings and accepts native JSON comments and trailing commas' {
        $json = @'
{
  // A literal example filter, not a timestamp value.
  "documentation": {"examples": {"sources": [
    {"path": "tests", "include": ["2026-10-07T00:00:00Z"]},
  ]}},
}
'@
        [IO.File]::WriteAllText((Join-Path $script:root 'bicepconfig.json'), $json)
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Path = $script:module; Stages = $script:stages } {
            param($Root, $Path, $Stages)
            $configuration = Get-AvmBicepDocsConfiguration -ModulePath $Path
            $null = Get-AvmBicepDocsRenderInput -SourcePath (Join-Path $Path 'main.bicep') `
                -Root $Root -Configuration $configuration -Stages $Stages
            [IO.File]::ReadAllText((Join-Path $Stages[$Root] 'bicepconfig.json')) |
                Should -Match '"2026-10-07T00:00:00Z"'
        }
    }

    It 'keeps nested compiler configuration inheritance in the temporary tree' {
        [IO.File]::WriteAllText((Join-Path $script:root 'base.json'), '{"analyzers":{"core":{"enabled":false}}}')
        [IO.File]::WriteAllText((Join-Path $script:module 'bicepconfig.json'), '{"extends":"../base.json"}')
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Path = $script:module; Stages = $script:stages } {
            param($Root, $Path, $Stages)
            $configuration = Get-AvmBicepDocsConfiguration -ModulePath $Path
            $renderInput = Get-AvmBicepDocsRenderInput -SourcePath (Join-Path $Path 'main.bicep') `
                -Root $Root -Configuration $configuration -Stages $Stages
            $config = [IO.File]::ReadAllText((Join-Path $renderInput.WorkingDirectory 'bicepconfig.json')) |
                ConvertFrom-Json -AsHashtable
            $config.extends | Should -BeExactly '../base.json'
            Test-Path -LiteralPath (Join-Path $renderInput.WorkingDirectory '..' 'base.json') | Should -BeTrue
        }
    }

    It 'allows read-only caller sources and configuration without changing their attributes' {
        $configPath = Join-Path $script:root 'bicepconfig.json'
        [IO.File]::WriteAllText($configPath, '{}')
        [IO.File]::SetAttributes($configPath, [IO.FileAttributes]::ReadOnly)
        try {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Path = $script:module; Stages = $script:stages } {
                param($Root, $Path, $Stages)
                $configuration = Get-AvmBicepDocsConfiguration -ModulePath $Path
                $null = Get-AvmBicepDocsRenderInput -SourcePath (Join-Path $Path 'main.bicep') `
                    -Root $Root -Configuration $configuration -Stages $Stages
                ([IO.File]::GetAttributes((Join-Path $Root 'bicepconfig.json')) -band [IO.FileAttributes]::ReadOnly) |
                    Should -Not -Be 0
                ([IO.File]::GetAttributes((Join-Path $Stages[$Root] 'bicepconfig.json')) -band [IO.FileAttributes]::ReadOnly) |
                    Should -Be 0
            }
        }
        finally { [IO.File]::SetAttributes($configPath, [IO.FileAttributes]::Normal) }
    }

    It 'does not cache a partially copied tree after a source-entry failure' {
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Path = $script:module; Stages = $script:stages } {
            param($Root, $Path, $Stages)
            $script:copiedStage = ''
            $script:archiveResolver = (Get-Command Resolve-AvmArchiveEntryPath).ScriptBlock
            $script:originalChildItem = Get-Command Get-ChildItem -CommandType Cmdlet
            Mock Resolve-AvmArchiveEntryPath {
                $script:copiedStage = $TargetDir
                & $script:archiveResolver @PesterBoundParameters
            }
            Mock Get-ChildItem { & $script:originalChildItem @PesterBoundParameters }
            Mock Get-ChildItem {
                & $script:originalChildItem -LiteralPath $LiteralPath -Force
                [pscustomobject]@{
                    Name = 'linked-source'; FullName = Join-Path $LiteralPath 'linked-source'
                    Attributes = [IO.FileAttributes]::ReparsePoint
                }
            } -ParameterFilter { $LiteralPath -eq $Root }
            $configuration = Get-AvmBicepDocsConfiguration -ModulePath $Path
            { Get-AvmBicepDocsRenderInput -SourcePath (Join-Path $Path 'main.bicep') `
                    -Root $Root -Configuration $configuration -Stages $Stages } |
                Should -Throw '*linked source entry*'
            $Stages.Count | Should -Be 0
            $script:copiedStage | Should -Not -BeNullOrEmpty
            [IO.Directory]::Exists($script:copiedStage) | Should -BeFalse
        }
    }

    It 'rejects a staging directory inside the selected source tree before copying' {
        InModuleScope Avm.Authoring -Parameters @{ Path = $script:module; Stages = $script:stages } {
            param($Path, $Stages)
            $configuration = Get-AvmBicepDocsConfiguration -ModulePath $Path
            { Get-AvmBicepDocsRenderInput -SourcePath (Join-Path $Path 'main.bicep') `
                    -Root ([IO.Path]::GetTempPath()) -Configuration $configuration -Stages $Stages } |
                Should -Throw '*outside the source tree*'
            $Stages.Count | Should -Be 0
        }
    }
}
