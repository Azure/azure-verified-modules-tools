#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring')
    $script:fixtureRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'fixtures' 'modules' 'bicep-docs')
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

    function New-BicepDocsGroupedReadme {
        $parameters = InModuleScope 'Avm.Authoring' {
            ConvertTo-AvmBicepDocsExampleParameter -Parameters @{
                name     = @{ value = 'demo' }
                location = @{ value = 'eastus' }
            } -RequiredParameters @('name')
        }
        $content = @'
## Usage examples

- [Provision storage](#example-1-provision-storage)

### Example 1: _Provision storage_

<details>

<summary>via Bicep module</summary>

```bicep
module example 'br/public:avm/res/storage/storage-account:<version>' = {
  params: {
__BICEP__
  }
}
```

</details>
<p>

<details>

<summary>via JSON parameters file</summary>

```json
__JSON__
```

</details>
<p>

<details>

<summary>via Bicep parameters file</summary>

```bicep-params
using 'br/public:avm/res/storage/storage-account:<version>'
__PARAMS__
```

</details>
<p>

## Parameters

| Parameter | Type |
| :-- | :-- |
| name | `string` |
| location | `string` |

## Outputs

| Output | Type |
| :-- | :-- |
| resourceId | `string` |
'@
        $content = $content.ReplaceLineEndings("`n")
        $content = $content.Replace('__BICEP__', $parameters.BicepParameters)
        $content = $content.Replace('__JSON__', $parameters.JsonParameters)
        return $content.Replace('__PARAMS__', $parameters.BicepParameterFile) + "`n"
    }

    function Remove-BicepDocsJsonGroupingComments {
        param([Parameter(Mandatory)][string] $Content)

        return $Content.Replace(
            "  `"parameters`": {`n    // Required parameters`n",
            "  `"parameters`": {`n").Replace(
            "    // Non-required parameters`n    `"location`": {",
            '    "location": {')
    }

    function New-BicepDocsGroupedCustomValues {
        param([Parameter(Mandatory)][string] $Content)

        $fragment = [regex]::Match($Content, '(?s)```json\n(.*?)\n```').Groups[1].Value
        return [pscustomobject]@{
            Fragment = $fragment
            Values   = @{
                moduleReference = 'avm/res/storage/storage-account'
                examples        = ConvertTo-Json -InputObject @{
                    'tests/e2e/full/main.test.bicep' = @{
                        IsModule = $true; JsonParameters = $fragment
                    }
                } -Compress -Depth 10
            }
        }
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
            $preview.ValidationSummary.Total | Should -Be 2
            $preview.ValidationSummary.Failed | Should -Be 2
            $preview.GeneratedReadmes[0].Content | Should -BeExactly "# Root`n"
            @($preview.Issues | Where-Object { $_.Code -eq 'avm.bicep.docs-missing' }).Count |
                Should -Be 2
            Test-Path -LiteralPath (Join-Path $F.Module 'README.md') | Should -BeFalse

            $written = Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck
            $written.Status | Should -BeExactly 'pass'
            $written.Changed.Count | Should -Be 2
            $written.FilesProcessed | Should -Be 2
            $written.ValidationSummary | Should -BeNullOrEmpty
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'README.md')) |
                Should -BeExactly "# Root`n"
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'child' 'README.md')) |
                Should -BeExactly "# Child`n"
            $before = [System.IO.File]::GetLastWriteTimeUtc((Join-Path $F.Module 'README.md'))

            $clean = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $clean.Status | Should -BeExactly 'pass'
            $clean.Issues.Count | Should -Be 0
            $clean.Changed.Count | Should -Be 0
            $clean.ValidationSummary.Total | Should -Be 4
            $clean.ValidationSummary.Passed | Should -Be 4
            [System.IO.File]::GetLastWriteTimeUtc((Join-Path $F.Module 'README.md')) |
                Should -Be $before
            $script:references | Should -Contain 'avm/res/storage/storage-account'
            $script:references | Should -Contain 'avm/res/storage/storage-account/child'
            foreach ($path in $script:customPaths) {
                Test-Path -LiteralPath $path | Should -BeFalse
            }
            [System.IO.File]::WriteAllBytes((Join-Path $F.Module 'README.md'), [byte[]]@())
            $empty = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $empty.Status | Should -Be 'fail'
            $empty.ValidationSummary.Total | Should -Be 4
            $empty.ValidationSummary.Failed | Should -Be 1
            $empty.Issues.Code | Should -Contain 'avm.bicep.docs-stale'
            $empty.Issues.Code | Should -Not -Contain 'avm.bicep.docs-missing'
        }
    }

    It 'rejects an incomplete native README run: <Kind>' -ForEach @(
        @{ Kind = 'unregistered'; Expected = -1; Passed = 4; Failed = 0 }
        @{ Kind = 'missing test'; Expected = 4; Passed = 3; Failed = 0 }
        @{ Kind = 'unmapped failure'; Expected = 4; Passed = 3; Failed = 1 }
    ) {
        $fixture = New-BicepDocsFixture -Name ('incomplete-' + $Kind.Replace(' ', '-'))
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture; Expected = $Expected; Passed = $Passed; Failed = $Failed } {
            param($F, $Expected, $Passed, $Failed)
            $script:expectedCount = $Expected
            $script:passedCount = $Passed
            $script:failedCount = $Failed
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = "# Generated`n"; StdErr = '' } }
            Mock Invoke-AvmBicepPesterSuite {
                $ConventionData.NativeReadmeExpected = $script:expectedCount
                @{
                    Version = 'test'; Total = $script:passedCount + $script:failedCount
                    Passed = $script:passedCount; Failed = $script:failedCount
                    Skipped = 0; Inconclusive = 0; Filtered = 0; Issues = @()
                }
            }
            $result = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $result.Status | Should -Be 'fail'
            $result.Issues.Code | Should -Contain 'avm.bicep.docs-suite-incomplete'
        }
    }

    It 'warns only for missing generated JSON comments and writes the unmodified renderer output' {
        $fixture = New-BicepDocsFixture -Name 'grouped-json-comments'
        $generated = New-BicepDocsGroupedReadme
        $custom = New-BicepDocsGroupedCustomValues -Content $generated
        $tracked = Remove-BicepDocsJsonGroupingComments -Content $generated
        $rootReadme = Join-Path $fixture.Module 'README.md'
        $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
        [System.IO.File]::WriteAllText($rootReadme, $tracked, $utf8)
        [System.IO.File]::WriteAllText(
            (Join-Path $fixture.Module 'child' 'README.md'), "# Child`n", $utf8)
        InModuleScope 'Avm.Authoring' -Parameters @{
            F = $fixture; Expected = $generated; Authored = $tracked
            Custom = $custom
        } {
            param($F, $Expected, $Authored, $Custom)
            $script:expectedReadme = $Expected
            $script:originalJson = $Custom.Fragment
            $script:customValues = $Custom.Values
            $script:renderArgs = [System.Collections.Generic.List[object]]::new()
            $script:renderPaths = [System.Collections.Generic.List[string]]::new()
            Mock Get-AvmBicepDocsCustomValue { $script:customValues }
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                $script:renderArgs.Add(@($ArgumentList))
                $script:renderPaths.Add($ArgumentList[5])
                $content = if ($WorkingDirectory -match 'child$') {
                    "# Child`n"
                }
                else {
                    $data = [System.IO.File]::ReadAllText($ArgumentList[5]) |
                    ConvertFrom-Json -AsHashtable
                    $examples = $data.examples | ConvertFrom-Json -AsHashtable
                    $fragment = $examples['tests/e2e/full/main.test.bicep'].JsonParameters
                    $script:expectedReadme.Replace($script:originalJson, $fragment)
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = $content; StdErr = '' }
            }

            $previousOffline = $env:AVM_OFFLINE
            try {
                $env:AVM_OFFLINE = '1'
                $preview = Invoke-AvmDocs -Path $F.Root -CheckDrift `
                    -IncludeRenderedContent -SkipModuleVersionCheck
            }
            finally {
                $env:AVM_OFFLINE = $previousOffline
            }
            $preview.Status | Should -BeExactly 'pass'
            $preview.FilesSelected | Should -Be 2
            $preview.FilesProcessed | Should -Be 2
            $preview.Issues.Count | Should -Be 1
            $preview.Issues[0].Code | Should -BeExactly 'avm.bicep.docs-example-comments'
            $preview.Issues[0].Severity | Should -BeExactly 'warning'
            $preview.Issues[0].Message | Should -Match '2 generated JSON-example'
            $preview.GeneratedReadmes[0].Content | Should -BeExactly $Expected
            $script:renderArgs.Count | Should -Be 3
            foreach ($invocation in $script:renderArgs) {
                ($invocation -contains '--no-restore') | Should -BeTrue
            }
            foreach ($path in $script:renderPaths) {
                Test-Path -LiteralPath $path | Should -BeFalse
            }
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'README.md')) |
                Should -BeExactly $Authored

            $written = Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck
            $written.Status | Should -BeExactly 'pass'
            $written.Changed.Count | Should -Be 1
            [System.Linq.Enumerable]::SequenceEqual(
                [byte[]][System.IO.File]::ReadAllBytes((Join-Path $F.Module 'README.md')),
                [byte[]][System.Text.UTF8Encoding]::new($false).GetBytes($Expected)) |
                Should -BeTrue
            $clean = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $clean.Issues.Count | Should -Be 0

            $otherDrift = $Authored.Replace('"value": "demo"', '"value": "other"')
            [System.IO.File]::WriteAllText(
                (Join-Path $F.Module 'README.md'), $otherDrift,
                [System.Text.UTF8Encoding]::new($false))
            $stale = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $stale.Status | Should -BeExactly 'fail'
            $stale.Issues.Count | Should -Be 1
            $stale.Issues[0].Code | Should -BeExactly 'avm.bicep.docs-stale'
        }
    }

    It 'retains render failures and source-less warnings alongside a valid comment exception' {
        $fixture = New-BicepDocsFixture -Name 'grouped-json-incomplete'
        $generated = New-BicepDocsGroupedReadme
        $custom = New-BicepDocsGroupedCustomValues -Content $generated
        $tracked = Remove-BicepDocsJsonGroupingComments -Content $generated
        $rootReadme = Join-Path $fixture.Module 'README.md'
        $static = Join-Path $fixture.Root 'avm' 'ptn' 'aca-lza' 'hosting-environment' 'modules' 'spoke'
        $null = New-Item -ItemType Directory -Path $static -Force
        [System.IO.File]::WriteAllText($rootReadme, $tracked)
        [System.IO.File]::WriteAllText((Join-Path $static 'README.md'), "# Static`n")
        InModuleScope 'Avm.Authoring' -Parameters @{
            F = $fixture; Generated = $generated; Authored = $tracked
            Custom = $custom
        } {
            param($F, $Generated, $Authored, $Custom)
            $script:expectedReadme = $Generated
            $script:originalJson = $Custom.Fragment
            $script:customValues = $Custom.Values
            Mock Get-AvmBicepDocsCustomValue { $script:customValues }
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                if ($WorkingDirectory -match 'child$') {
                    return [pscustomobject]@{
                        ExitCode = 1; StdOut = ''; StdErr = 'BCP190: missing dependency'
                    }
                }
                $data = [System.IO.File]::ReadAllText($ArgumentList[5]) |
                ConvertFrom-Json -AsHashtable
                $examples = $data.examples | ConvertFrom-Json -AsHashtable
                $fragment = $examples['tests/e2e/full/main.test.bicep'].JsonParameters
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = $script:expectedReadme.Replace(
                        $script:originalJson, $fragment)
                    StdErr = ''
                }
            }

            $preview = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $preview.Status | Should -BeExactly 'fail'
            $preview.FilesSelected | Should -Be 2
            $preview.FilesProcessed | Should -Be 1
            @($preview.Issues | Where-Object Code -EQ 'avm.bicep.docs-example-comments').Count |
                Should -Be 1
            @($preview.Issues | Where-Object Code -EQ 'avm.bicep.docs-render-failed').Count |
                Should -Be 1
            @($preview.Issues | Where-Object Code -EQ 'avm.bicep.docs-no-source').Count |
                Should -Be 1
            $preview.NotRendered | Should -Contain 'avm/ptn/aca-lza/hosting-environment/modules/spoke/README.md'
            { Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck } |
                Should -Throw '*BCP190: missing dependency*'
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'README.md')) |
                Should -BeExactly $Authored
            [System.IO.File]::ReadAllText(
                (Join-Path $F.Root 'avm' 'ptn' 'aca-lza' 'hosting-environment' 'modules' 'spoke' 'README.md')) |
                Should -BeExactly "# Static`n"
        }
    }

    It 'distinguishes generated comments from authored full frames and nested Markdown' {
        $fixture = New-BicepDocsFixture -Name 'grouped-json-authored-frame'
        $base = New-BicepDocsGroupedReadme
        $custom = New-BicepDocsGroupedCustomValues -Content $base
        $start = $base.IndexOf('<details>', [System.StringComparison]::Ordinal)
        $end = $base.IndexOf("`n`n## Parameters", $start, [System.StringComparison]::Ordinal)
        $authoredFrame = $base.Substring($start, $end - $start).Replace(
            '"value": "demo"', '"value": "authored"')
        $anchor = "### Example 1: _Provision storage_`n`n"
        $authored = "### Authored aside`n`n$authoredFrame`n`n" +
        "## Nested note`n`n<details>`n<summary>Authored</summary>`n</details>`n`n"
        $generated = $base.Replace($anchor, $anchor + $authored)
        $fakeJson = [regex]::Match($authoredFrame,
            '(?s)```json\n(.*?)\n```').Groups[1].Value
        $tracked = $generated.Replace(
            $fakeJson, (Remove-BicepDocsJsonGroupingComments -Content $fakeJson))
        $readme = Join-Path $fixture.Module 'README.md'
        [System.IO.File]::WriteAllText($readme, $tracked)
        [System.IO.File]::WriteAllText(
            (Join-Path $fixture.Module 'child' 'README.md'), "# Child`n")

        InModuleScope 'Avm.Authoring' -Parameters @{
            F = $fixture; Generated = $generated; Custom = $custom
            Tracked = $tracked
        } {
            param($F, $Generated, $Custom, $Tracked)
            $script:expectedReadme = $Generated
            $script:originalJson = $Custom.Fragment
            $script:customValues = $Custom.Values
            Mock Get-AvmBicepDocsCustomValue { $script:customValues }
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                if ($WorkingDirectory -match 'child$') {
                    return [pscustomobject]@{
                        ExitCode = 0; StdOut = "# Child`n"; StdErr = ''
                    }
                }
                $data = [System.IO.File]::ReadAllText($ArgumentList[5]) |
                ConvertFrom-Json -AsHashtable
                $examples = $data.examples | ConvertFrom-Json -AsHashtable
                $fragment = $examples['tests/e2e/full/main.test.bicep'].JsonParameters
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut  = $script:expectedReadme.Replace(
                        $script:originalJson, $fragment)
                    StdErr  = ''
                }
            }

            $authoredDrift = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $authoredDrift.Status | Should -BeExactly 'fail'
            @($authoredDrift.Issues | Where-Object Code -EQ 'avm.bicep.docs-stale').Count |
                Should -Be 1
            @($authoredDrift.Issues | Where-Object Code -EQ 'avm.bicep.docs-example-comments').Count |
                Should -Be 0
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'README.md')) |
                Should -BeExactly $Tracked

            $realWithoutComments = $script:originalJson.Replace(
                "    // Required parameters`n", '').Replace(
                "    // Non-required parameters`n", '')
            $realDrift = $Generated.Replace($script:originalJson, $realWithoutComments)
            [System.IO.File]::WriteAllText((Join-Path $F.Module 'README.md'), $realDrift)
            $accepted = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $accepted.Status | Should -BeExactly 'pass'
            @($accepted.Issues | Where-Object Code -EQ 'avm.bicep.docs-example-comments').Count |
                Should -Be 1
            $changedProse = $realDrift.Replace('### Authored aside', '### Changed aside')
            [System.IO.File]::WriteAllText((Join-Path $F.Module 'README.md'), $changedProse)
            $rejected = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $rejected.Status | Should -BeExactly 'fail'
            @($rejected.Issues | Where-Object Code -EQ 'avm.bicep.docs-stale').Count |
                Should -Be 1
        }
    }

    It 'fails closed with named diagnostics when the private provenance render fails' {
        $fixture = New-BicepDocsFixture -Name 'grouped-json-probe-failure'
        $generated = New-BicepDocsGroupedReadme
        $custom = New-BicepDocsGroupedCustomValues -Content $generated
        $tracked = Remove-BicepDocsJsonGroupingComments -Content $generated
        [System.IO.File]::WriteAllText((Join-Path $fixture.Module 'README.md'), $tracked)
        [System.IO.File]::WriteAllText(
            (Join-Path $fixture.Module 'child' 'README.md'), "# Child`n")

        InModuleScope 'Avm.Authoring' -Parameters @{
            F = $fixture; Generated = $generated; Custom = $custom
            Tracked = $tracked
        } {
            param($F, $Generated, $Custom, $Tracked)
            $script:expectedReadme = $Generated
            $script:originalJson = $Custom.Fragment
            $script:customValues = $Custom.Values
            Mock Get-AvmBicepDocsCustomValue { $script:customValues }
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                if ($WorkingDirectory -match 'child$') {
                    return [pscustomobject]@{
                        ExitCode = 0; StdOut = "# Child`n"; StdErr = ''
                    }
                }
                $data = [System.IO.File]::ReadAllText($ArgumentList[5]) |
                ConvertFrom-Json -AsHashtable
                $examples = $data.examples | ConvertFrom-Json -AsHashtable
                $fragment = $examples['tests/e2e/full/main.test.bicep'].JsonParameters
                if ($fragment -match '__AVM_DOCS_REQUIRED_') {
                    return [pscustomobject]@{
                        ExitCode = 1; StdOut = ''; StdErr = 'BCP190: synthetic probe failure'
                    }
                }
                [pscustomobject]@{
                    ExitCode = 0; StdOut = $script:expectedReadme; StdErr = ''
                }
            }

            $failed = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $failed.Status | Should -BeExactly 'fail'
            @($failed.Issues | Where-Object Code -EQ 'avm.bicep.docs-provenance-failed').Count |
                Should -Be 1
            @($failed.Issues | Where-Object Code -EQ 'avm.bicep.docs-example-comments').Count |
                Should -Be 0
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'README.md')) |
                Should -BeExactly $Tracked
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
            $failure = @($result.Issues | Where-Object { $_.Code -eq 'avm.bicep.docs-render-failed' })
            $failure | Should -HaveCount 1
            $failure[0].Message | Should -Match 'BCP426: child failure'
            $failure[0].File | Should -BeExactly 'avm/res/storage/storage-account/child/README.md'
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

    It 'rejects invalid test examples without writing any planned README' {
        $fixture = New-BicepDocsFixture -Name 'invalid-example'
        $readme = Join-Path $fixture.Module 'README.md'
        [System.IO.File]::WriteAllText($readme, "Original`n")
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
            }
            Mock Invoke-AvmProcess {
                if ($WorkingDirectory -match 'child$') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = "__AVM_DOCS_INVALID_EXAMPLE__:Bicep test 'tests/e2e/minimal/main.test.bicep' targets 'avm/res/storage/storage-account/main.bicep' with unknown parameters: wrongName; missing required parameters: name. Correct the test before generating its README.`n"
                        StdErr   = ''
                    }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = "# New root`n"; StdErr = '' }
            }
            $drift = Invoke-AvmDocs -Path $F.Root -CheckDrift `
                -IncludeRenderedContent -SkipModuleVersionCheck
            $drift.Status | Should -BeExactly 'fail'
            $drift.FilesProcessed | Should -Be 1
            $drift.GeneratedReadmes.Count | Should -Be 1
            $failures = @($drift.Issues | Where-Object Code -EQ 'avm.bicep.docs-render-failed')
            $failures.Count | Should -Be 1
            $failures[0].Message |
                Should -Match 'unknown parameters: wrongName; missing required parameters: name'
            { Invoke-AvmDocs -Path $F.Root -SkipModuleVersionCheck } |
                Should -Throw '*unknown parameters: wrongName; missing required parameters: name*'
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'README.md')) |
                Should -BeExactly "Original`n"
            Test-Path -LiteralPath (Join-Path $F.Module 'child' 'README.md') |
                Should -BeFalse
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
            $result.Status | Should -BeExactly 'pass'
            $result.FilesProcessed | Should -Be 3
            $result.NotRendered | Should -Contain 'avm/ptn/aca-lza/hosting-environment/modules/spoke/README.md'
            $result.Issues[0].Code | Should -BeExactly 'avm.bicep.docs-no-source'
            $result.Issues[0].Severity | Should -BeExactly 'warning'
            [System.IO.File]::ReadAllText((Join-Path $F.Module 'README.md')) |
                Should -BeExactly "# Rendered`n"
            [System.IO.File]::ReadAllText(
                (Join-Path $F.Root 'avm' 'ptn' 'aca-lza' 'hosting-environment' 'modules' 'spoke' 'README.md')) |
                Should -BeExactly "# Walkthrough`n"

            $drift = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
            $drift.Status | Should -BeExactly 'pass'
            $drift.Changed.Count | Should -Be 0
            $drift.Issues[0].Code | Should -BeExactly 'avm.bicep.docs-no-source'
            $drift.NotRendered.Count | Should -Be 1
        }
    }

    It 'disables Bicep docs restoration in offline mode, including fallback source compilation' {
        $fixture = New-BicepDocsFixture -Name 'offline-no-restore'
        $jsonPath = Join-Path $fixture.Module 'main.json'
        $compiledJson = [System.IO.File]::ReadAllText($jsonPath)
        Remove-Item -LiteralPath $jsonPath
        InModuleScope 'Avm.Authoring' -Parameters @{
            F = $fixture; CompiledJson = $compiledJson
        } {
            param($F, $CompiledJson)
            $script:offlineCompiledJson = $CompiledJson
            $previous = $env:AVM_OFFLINE
            try {
                $env:AVM_OFFLINE = '1'
                Mock Resolve-AvmTool {
                    [pscustomobject]@{ Name = 'bicep'; Version = 'test'; Path = 'mock-bicep'; Source = 'test' }
                }
                Mock Invoke-AvmProcess {
                    if ($ArgumentList[0] -eq 'build') {
                        return [pscustomobject]@{
                            ExitCode = 0; StdOut = $script:offlineCompiledJson; StdErr = ''
                        }
                    }
                    [pscustomobject]@{ ExitCode = 0; StdOut = "# Rendered`n"; StdErr = '' }
                }
                $result = Invoke-AvmDocs -Path $F.Root -CheckDrift -SkipModuleVersionCheck
                $result.FilesProcessed | Should -Be 2
                Should -Invoke Invoke-AvmProcess -ParameterFilter {
                    $ArgumentList[0] -eq 'build' -and $ArgumentList -contains '--no-restore'
                }
                Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter {
                    $ArgumentList[0] -eq 'docs' -and $ArgumentList -contains '--no-restore'
                }
                Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter {
                    $ArgumentList -notcontains '--no-restore'
                }
            }
            finally {
                if ($null -eq $previous) {
                    Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
                }
                else {
                    $env:AVM_OFFLINE = $previous
                }
            }
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
            $childTemplate = @{
                parameters = @{
                    childOnly = @{ type = 'string' }
                }
            }
            Get-AvmBicepDocsExample -ModulePath $Child -RepositoryRoot $F.Root `
                -ToolPath 'mock-bicep' -CompiledTemplate $childTemplate `
                -RequiredParameters @('childOnly')
        }
        $example = $examples['../tests/e2e/rg-scope.minimal/main.test.bicep']
        $example.IsModule | Should -BeTrue
        $example.InvalidReason | Should -BeExactly ''
        $example.Parameters.name.value | Should -BeExactly 'avmdocs12345'
        $example.BicepParameters | Should -BeExactly "    name: 'avmdocs12345'"
        $example.JsonParameters | Should -Match '"contentVersion": "1.0.0.0"'
        $example.BicepParameterFile | Should -BeExactly "param name = 'avmdocs12345'"
        Test-Path -LiteralPath (Join-Path $fixture.Module 'README.md') | Should -BeFalse
    }

    It 'reads module-root tests for the root and nested scopes without scanning above the selected root' {
        $fixture = New-BicepDocsFixture -Name 'example-module-boundary'
        $child = Join-Path $fixture.Module 'rg-scope'
        $null = New-Item -ItemType Directory -Path $child -Force
        Copy-Item -LiteralPath (Join-Path $fixture.Module 'child' 'main.bicep') `
            -Destination (Join-Path $child 'main.bicep')
        Copy-Item -LiteralPath (Join-Path $fixture.Module 'child' 'main.json') `
            -Destination (Join-Path $child 'main.json')
        $outside = Join-Path $fixture.Root 'tests' 'e2e' 'outside'
        $null = New-Item -ItemType Directory -Path $outside -Force
        Copy-Item -LiteralPath (Join-Path $fixture.Module 'tests' 'e2e' 'rg-scope.minimal' 'main.test.bicep') `
            -Destination (Join-Path $outside 'main.test.bicep')

        $examples = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture; Child = $child } {
            param($F, $Child)
            $rootTemplate = Get-Content -LiteralPath (Join-Path $F.Module 'main.json') `
                -Raw | ConvertFrom-Json -AsHashtable
            $childTemplate = Get-Content -LiteralPath (Join-Path $Child 'main.json') `
                -Raw | ConvertFrom-Json -AsHashtable
            $moduleRoot = Get-AvmBicepDocsExample -ModulePath $F.Module `
                -RepositoryRoot $F.Module -ToolPath 'mock-bicep' `
                -CompiledTemplate $rootTemplate -RequiredParameters @('name')
            $nestedScope = Get-AvmBicepDocsExample -ModulePath $Child `
                -RepositoryRoot $F.Module -ToolPath 'mock-bicep' `
                -CompiledTemplate $childTemplate
            $repositoryRoot = Get-AvmBicepDocsExample -ModulePath $Child `
                -RepositoryRoot $F.Root -ToolPath 'mock-bicep' `
                -CompiledTemplate $childTemplate
            [pscustomobject]@{
                ModuleRoot     = $moduleRoot
                NestedScope    = $nestedScope
                RepositoryRoot = $repositoryRoot
            }
        }
        @($examples.ModuleRoot.Keys | Sort-Object) | Should -Be @(
            'tests/e2e/rg-scope.max/main.test.bicep',
            'tests/e2e/rg-scope.minimal/main.test.bicep'
        )
        @($examples.NestedScope.Keys | Sort-Object) |
            Should -Be @($examples.RepositoryRoot.Keys | Sort-Object)
        @($examples.NestedScope.Keys).Count | Should -Be 4
        $examples.NestedScope['../tests/e2e/rg-scope.minimal/main.test.bicep'].InvalidReason |
            Should -BeExactly ''
        @($examples.NestedScope.Keys | Where-Object { $_ -match 'outside' }).Count |
            Should -Be 0
    }

    It 'identifies unknown and missing parameters in a referenced ancestor test' {
        $fixture = New-BicepDocsFixture -Name 'invalid-source-parameters'
        $child = Join-Path $fixture.Module 'rg-scope'
        $null = New-Item -ItemType Directory -Path $child -Force
        $testFile = [System.IO.Path]::Combine(
            $fixture.Module, 'tests', 'e2e', 'rg-scope.minimal', 'main.test.bicep')
        $source = [System.IO.File]::ReadAllText($testFile).Replace(
            "name: 'avmdocs12345'", "wrongName: 'invalid'")
        [System.IO.File]::WriteAllText(
            $testFile, $source, [System.Text.UTF8Encoding]::new($false))

        $examples = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture; Child = $child } {
            param($F, $Child)
            Get-AvmBicepDocsExample -ModulePath $Child -RepositoryRoot $F.Root `
                -ToolPath 'mock-bicep' -CompiledTemplate @{
                    parameters = @{ childOnly = @{ type = 'string' } }
                } -RequiredParameters @('childOnly')
        }
        $invalid = $examples['../tests/e2e/rg-scope.minimal/main.test.bicep']
        $invalid.InvalidReason | Should -Match 'tests/e2e/rg-scope.minimal/main.test.bicep'
        $invalid.InvalidReason | Should -Match 'storage-account/main.bicep'
        $invalid.InvalidReason |
            Should -Match 'unknown parameters: wrongName; missing required parameters: name'
        $invalid.BicepParameters | Should -BeExactly ''
        $invalid.JsonParameters | Should -BeExactly ''
        $examples['../tests/e2e/rg-scope.max/main.test.bicep'].InvalidReason |
            Should -BeExactly ''
    }

    It 'rejects invalid root test parameters when the module is the boundary' {
        $fixture = New-BicepDocsFixture -Name 'invalid-root-test'
        $testFile = [System.IO.Path]::Combine(
            $fixture.Module, 'tests', 'e2e', 'rg-scope.minimal', 'main.test.bicep')
        $source = [System.IO.File]::ReadAllText($testFile).Replace(
            "name: 'avmdocs12345'", "wrongName: 'invalid'")
        [System.IO.File]::WriteAllText(
            $testFile, $source, [System.Text.UTF8Encoding]::new($false))

        $examples = InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            $template = Get-Content -LiteralPath (Join-Path $F.Module 'main.json') `
                -Raw | ConvertFrom-Json -AsHashtable
            Get-AvmBicepDocsExample -ModulePath $F.Module -RepositoryRoot $F.Module `
                -ToolPath 'mock-bicep' -CompiledTemplate $template -RequiredParameters @('name')
        }
        $invalid = $examples['tests/e2e/rg-scope.minimal/main.test.bicep']
        $invalid.InvalidReason |
            Should -Match 'unknown parameters: wrongName; missing required parameters: name'
        $invalid.BicepParameters | Should -BeExactly ''
    }

    It 'rejects example discovery outside the selected root' {
        $fixture = New-BicepDocsFixture -Name 'example-outside-boundary'
        InModuleScope 'Avm.Authoring' -Parameters @{ F = $fixture } {
            param($F)
            $template = Get-Content -LiteralPath (Join-Path $F.Module 'main.json') `
                -Raw | ConvertFrom-Json -AsHashtable
            { Get-AvmBicepDocsExample -ModulePath $F.Module `
                    -RepositoryRoot (Join-Path $F.Module 'child') `
                    -ToolPath 'mock-bicep' -CompiledTemplate $template } |
                Should -Throw '*outside the repository root*'
        }
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
