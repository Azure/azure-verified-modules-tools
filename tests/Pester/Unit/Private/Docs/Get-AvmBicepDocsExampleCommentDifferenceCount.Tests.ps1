#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    function New-GroupedExampleReadme {
        param(
            [int] $Examples = 1,
            [int[]] $OmitJsonGroups = @()
        )

        $example = @'
### Example __NUMBER__: _Provision storage_

<details>

<summary>via Bicep module</summary>

```bicep
module example 'br/public:avm/res/storage/storage-account:<version>' = {
  params: {
    // Required parameters
    name: 'demo'
    // Non-required parameters
    location: 'eastus'
  }
}
```

</details>
<p>

<details>

<summary>via JSON parameters file</summary>

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    // Required parameters
    "name": {
      "value": "demo"
    },
    // Non-required parameters
    "location": {
      "value": "eastus"
    }
  }
}
```

</details>
<p>

<details>

<summary>via Bicep parameters file</summary>

```bicep-params
using 'br/public:avm/res/storage/storage-account:<version>'
// Required parameters
param name = 'demo'
// Non-required parameters
param location = 'eastus'
```

</details>
<p>
'@
        $example = $example.ReplaceLineEndings("`n")
        $sections = [System.Collections.Generic.List[string]]::new()
        $toc = [System.Collections.Generic.List[string]]::new()
        for ($number = 1; $number -le $Examples; $number++) {
            $toc.Add("- [Provision storage](#example-$number-provision-storage)")
            $section = $example.Replace('__NUMBER__', [string]$number)
            if ($number -in $OmitJsonGroups) {
                $start = $section.IndexOf('```json', [System.StringComparison]::Ordinal)
                $end = $section.IndexOf(("`n" + '```'), $start + 7,
                    [System.StringComparison]::Ordinal)
                $json = $section.Substring($start, $end - $start)
                $withoutComments = $json.Replace("    // Required parameters`n", '')
                $withoutComments = $withoutComments.Replace("    // Non-required parameters`n", '')
                $section = $section.Substring(0, $start) + $withoutComments +
                $section.Substring($end)
            }
            $sections.Add($section)
        }
        return "## Usage examples`n`nIntroductory prose.`n`n" +
        ($toc.ToArray() -join "`n") + "`n`n" +
        ($sections.ToArray() -join "`n`n") +
        "`n`n## Parameters`n`n| Parameter | Type |`n| :-- | :-- |`n" +
        '| name | `string` |' + "`n" +
        "`n## Outputs`n`n| Output | Type |`n| :-- | :-- |`n" +
        '| resourceId | `string` |' + "`n"
    }

    function New-GeneratedExampleProbe {
        param([AllowEmptyString()][string] $Content)

        $rendered = $Content
        $markers = [System.Collections.Generic.List[object]]::new()
        $blocks = [regex]::Matches($Content, '(?s)```json\n(.*?)\n```')
        for ($index = $blocks.Count - 1; $index -ge 0; $index--) {
            $group = $blocks[$index].Groups[1]
            $requiredMarker = "__TEST_REQUIRED_${index}__"
            $nonRequiredMarker = "__TEST_NON_REQUIRED_${index}__"
            $marked = $group.Value.Replace(
                '    // Required parameters',
                $requiredMarker + '    // Required parameters').Replace(
                '    // Non-required parameters',
                $nonRequiredMarker + '    // Non-required parameters')
            if ($marked -ceq $group.Value) {
                continue
            }
            $rendered = $rendered.Substring(0, $group.Index) + $marked +
            $rendered.Substring($group.Index + $group.Length)
            $markers.Insert(0, [pscustomobject]@{
                    RequiredMarker    = $requiredMarker
                    NonRequiredMarker = $nonRequiredMarker
                })
        }
        return [pscustomobject]@{
            Content = $rendered
            Markers = $markers.ToArray()
        }
    }

    function Get-CommentDifferenceCount {
        param(
            [AllowEmptyString()][string] $Generated,
            [AllowEmptyString()][string] $Tracked,
            [AllowNull()] $Provenance
        )

        if ($null -eq $Provenance) {
            $Provenance = New-GeneratedExampleProbe -Content $Generated
        }
        $bytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($Tracked)
        InModuleScope 'Avm.Authoring' -Parameters @{
            Bytes = $bytes; Text = $Generated
            Probe = $Provenance.Content; Markers = $Provenance.Markers
        } {
            param($Bytes, $Text, $Probe, $Markers)
            Get-AvmBicepDocsExampleCommentDifferenceCount `
                -CurrentBytes $Bytes -GeneratedContent $Text `
                -ProbeContent $Probe -Markers $Markers
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepDocsExampleCommentDifferenceCount' {
    It 'accepts four missing JSON pairs while preserving an already-authored fifth pair' {
        $generated = New-GroupedExampleReadme -Examples 5
        $tracked = New-GroupedExampleReadme -Examples 5 -OmitJsonGroups @(2, 3, 4, 5)

        Get-CommentDifferenceCount -Generated $generated -Tracked $tracked | Should -Be 8
        Get-CommentDifferenceCount -Generated $tracked -Tracked $generated | Should -Be 0
    }

    It 'derives the count from complete usage-example JSON parameter groups, not a filename or number of examples' {
        $generated = New-GroupedExampleReadme
        $tracked = New-GroupedExampleReadme -OmitJsonGroups @(1)

        Get-CommentDifferenceCount -Generated $generated -Tracked $tracked | Should -Be 2
        Get-CommentDifferenceCount -Generated $generated -Tracked $generated | Should -Be 0
    }

    It 'rejects prose, Bicep code, JSON values, parameter types, outputs, unrelated comments, and byte drift' {
        $generated = New-GroupedExampleReadme
        $tracked = New-GroupedExampleReadme -OmitJsonGroups @(1)
        $changes = @{
            prose             = $tracked.Replace('Introductory prose.', 'Different prose.')
            bicepCode         = $tracked.Replace("name: 'demo'", "name: 'other'")
            jsonValue         = $tracked.Replace('"value": "demo"', '"value": "other"')
            parameterType     = $tracked.Replace('name | `string`', 'name | `object`')
            outputType        = $tracked.Replace('resourceId | `string`', 'resourceId | `object`')
            unrelatedComment  = $tracked.Replace('// Required parameters', '// Required values')
            jsonFence         = $tracked.Replace('```json', '```jsonc')
            trailingText      = $tracked + "`nAdditional text."
            lineEndings       = $tracked.Replace("`n", "`r`n")
            byteOrderMark     = [string][char]0xFEFF + $tracked
        }
        foreach ($name in $changes.Keys) {
            Get-CommentDifferenceCount -Generated $generated -Tracked $changes[$name] |
                Should -Be 0 -Because $name
        }
    }

    Describe 'Get-AvmBicepDocsExampleCommentProbe' {
        It 'marks only first-party JSON example comments and preserves normal values and output' {
            $generated = New-GroupedExampleReadme
            $tracked = New-GroupedExampleReadme -OmitJsonGroups @(1)
            $fragment = [regex]::Match($generated, '(?s)```json\n(.*?)\n```').Groups[1].Value
            $values = @{
                moduleReference = 'avm/res/storage/storage-account'
                notes           = 'Authored // Required parameters'
                examples        = ConvertTo-Json -InputObject @{
                    'tests/e2e/full/main.test.bicep' = @{
                        IsModule = $true; JsonParameters = $fragment
                    }
                } -Compress -Depth 10
            }
            $originalExamples = $values.examples
            $probe = InModuleScope 'Avm.Authoring' -Parameters @{
                Values = $values; Rendered = $generated
            } {
                param($Values, $Rendered)
                Get-AvmBicepDocsExampleCommentProbe `
                    -Values $Values -GeneratedContent $Rendered
            }

            $probe.Markers.Count | Should -Be 1
            $values.examples | Should -BeExactly $originalExamples
            $probe.Values.notes | Should -BeExactly $values.notes
            $marked = ($probe.Values.examples | ConvertFrom-Json -AsHashtable)[
                'tests/e2e/full/main.test.bicep'].JsonParameters
            $marked | Should -Match ([regex]::Escape(
                    $probe.Markers[0].RequiredMarker + '    // Required parameters'))
            $marked | Should -Match ([regex]::Escape(
                    $probe.Markers[0].NonRequiredMarker + '    // Non-required parameters'))
            $privateRender = $generated.Replace($fragment, $marked)
            Get-CommentDifferenceCount -Generated $generated -Tracked $tracked `
                -Provenance ([pscustomobject]@{
                    Content = $privateRender; Markers = $probe.Markers
                }) | Should -Be 2
        }

        It 'ignores unrendered child aliases but rejects a half-rendered pair' {
            $generated = New-GroupedExampleReadme
            $tracked = New-GroupedExampleReadme -OmitJsonGroups @(1)
            $fragment = [regex]::Match($generated, '(?s)```json\n(.*?)\n```').Groups[1].Value
            $renderedPath = 'tests/e2e/full/main.test.bicep'
            $values = @{
                examples = ConvertTo-Json -InputObject @{
                    $renderedPath = @{ JsonParameters = $fragment }
                    'child/tests/e2e/full/main.test.bicep' = @{
                        JsonParameters = $fragment
                    }
                } -Compress -Depth 10
            }
            $probe = InModuleScope 'Avm.Authoring' -Parameters @{
                Values = $values; Rendered = $generated
            } {
                param($Values, $Rendered)
                Get-AvmBicepDocsExampleCommentProbe `
                    -Values $Values -GeneratedContent $Rendered
            }
            $probe.Markers.Count | Should -Be 2
            $renderedFragment = ($probe.Values.examples | ConvertFrom-Json -AsHashtable)[
                $renderedPath].JsonParameters
            $usedMarker = @($probe.Markers | Where-Object {
                    $renderedFragment.Contains($_.RequiredMarker)
                })
            $usedMarker.Count | Should -Be 1
            $privateRender = $generated.Replace($fragment, $renderedFragment)
            Get-CommentDifferenceCount -Generated $generated -Tracked $tracked `
                -Provenance ([pscustomobject]@{
                    Content = $privateRender; Markers = $probe.Markers
                }) | Should -Be 2
            Get-CommentDifferenceCount -Generated $generated -Tracked $tracked `
                -Provenance ([pscustomobject]@{
                    Content = $privateRender.Replace(
                        $usedMarker[0].NonRequiredMarker, '')
                    Markers = $probe.Markers
                }) | Should -Be 0
        }

        It 'preserves varied values and Unicode while ignoring authored frames and marker-like text' {
            $unicode = 'caf' + [char]0x00E9 + ' ' + [char]0x03B2
            $exampleParams = @{
                name     = @{ value = $unicode }
                count    = @{ value = 7 }
                enabled  = @{ value = $true }
                labels   = @{ value = @{ nested = 'before' } }
                replicas = @{ value = @('alpha', 'beta') }
            }
            $fragments = InModuleScope 'Avm.Authoring' -Parameters @{
                ExampleParams = $exampleParams
            } {
                param($ExampleParams)
                ConvertTo-AvmBicepDocsExampleParameter -Parameters $ExampleParams `
                    -RequiredParameters @('name')
            }
            $fragment = $fragments.JsonParameters
            $authoredMarker = '__AVM_DOCS_REQUIRED_00000000000000000000000000000000_0__'
            $template = @'
## Usage examples

### Example 1: _Actual source_

__UNICODE__ in authored prose.
- [Authored heading](#example-2-authored-heading)
### Example 2: _Authored heading_
<details>
<summary>via Bicep module</summary>
```bicep
module authored 'br/public:avm/res/storage/storage-account:<version>' = {}
```
</details>
<p>
<details>
<summary>via JSON parameters file</summary>
```json
__AUTHORED_FRAGMENT__
```
</details>
<p>
<details>
<summary>via Bicep parameters file</summary>
```bicep-params
using 'br/public:avm/res/storage/storage-account:<version>'
```
</details>

## Authored section
<details><summary>Authored HTML</summary></details>
{{ example_data.JsonParameters }}
__AUTHORED_MARKER__

<details>
<summary>via JSON parameters file</summary>
```json
__REAL_FRAGMENT__
```
</details>

## Parameters
'@
            $template = $template.ReplaceLineEndings("`n").Replace(
                '__UNICODE__', $unicode).Replace(
                '__AUTHORED_MARKER__', $authoredMarker)
            $generated = $template.Replace('__AUTHORED_FRAGMENT__', $fragment).Replace(
                '__REAL_FRAGMENT__', $fragment)
            $values = @{
                notes    = "Authored $unicode $authoredMarker"
                examples = ConvertTo-Json -InputObject @{
                    'tests/e2e/full/main.test.bicep' = @{
                        JsonParameters = $fragment
                    }
                } -Compress -Depth 99
            }
            $probe = InModuleScope 'Avm.Authoring' -Parameters @{
                Values = $values; Rendered = $generated
            } {
                param($Values, $Rendered)
                Get-AvmBicepDocsExampleCommentProbe `
                    -Values $Values -GeneratedContent $Rendered
            }
            $probe.Values.notes | Should -BeExactly $values.notes
            $marked = ($probe.Values.examples | ConvertFrom-Json -AsHashtable)[
                'tests/e2e/full/main.test.bicep'].JsonParameters
            $privateRender = $template.Replace(
                '__AUTHORED_FRAGMENT__', $fragment).Replace(
                '__REAL_FRAGMENT__', $marked)
            $cleaned = $privateRender.Replace($probe.Markers[0].RequiredMarker, '')
            $cleaned = $cleaned.Replace($probe.Markers[0].NonRequiredMarker, '')
            [System.Linq.Enumerable]::SequenceEqual(
                [byte[]][System.Text.UTF8Encoding]::new($false).GetBytes($cleaned),
                [byte[]][System.Text.UTF8Encoding]::new($false).GetBytes($generated)) |
                Should -BeTrue

            $withoutComments = $fragment.Replace(
                "    // Required parameters`n", '').Replace(
                "    // Non-required parameters`n", '')
            $realOmission = $template.Replace(
                '__AUTHORED_FRAGMENT__', $fragment).Replace(
                '__REAL_FRAGMENT__', $withoutComments)
            $fakeOmission = $template.Replace(
                '__AUTHORED_FRAGMENT__', $withoutComments).Replace(
                '__REAL_FRAGMENT__', $fragment)
            $provenance = [pscustomobject]@{
                Content = $privateRender; Markers = $probe.Markers
            }
            Get-CommentDifferenceCount -Generated $generated -Tracked $realOmission `
                -Provenance $provenance | Should -Be 2
            Get-CommentDifferenceCount -Generated $generated -Tracked $fakeOmission `
                -Provenance $provenance | Should -Be 0

            $valueMutations = @(
                @('"value": 7', '"value": 8'),
                @('"value": true', '"value": false'),
                @('"nested": "before"', '"nested": "after"'),
                @('"alpha"', '"delta"')
            )
            foreach ($mutation in $valueMutations) {
                $changed = $withoutComments.Replace($mutation[0], $mutation[1])
                $changed.Equals($withoutComments, [System.StringComparison]::Ordinal) |
                    Should -BeFalse
                $tracked = $template.Replace(
                    '__AUTHORED_FRAGMENT__', $fragment).Replace(
                    '__REAL_FRAGMENT__', $changed)
                Get-CommentDifferenceCount -Generated $generated -Tracked $tracked `
                    -Provenance $provenance | Should -Be 0
            }
            Get-CommentDifferenceCount -Generated $generated `
                -Tracked $realOmission.Replace("`n", "`r`n") `
                -Provenance $provenance | Should -Be 0
            Get-CommentDifferenceCount -Generated $generated -Tracked $realOmission `
                -Provenance ([pscustomobject]@{
                    Content = $privateRender.Replace("`n", "`r`n")
                    Markers = $probe.Markers
                }) | Should -Be 0
            $differentUnicode = 'cafe' + [char]0x0301 + ' ' + [char]0x03B2
            Get-CommentDifferenceCount -Generated $generated `
                -Tracked $realOmission.Replace($unicode, $differentUnicode) `
                -Provenance $provenance | Should -Be 0
        }

        It 'does not instrument incomplete or malformed model pairs' {
            $generated = New-GroupedExampleReadme
            $fragment = [regex]::Match($generated, '(?s)```json\n(.*?)\n```').Groups[1].Value
            foreach ($badFragment in @(
                    $fragment.Replace('    // Non-required parameters', '    // Other parameters'),
                    $fragment.Replace('    // Required parameters', '    // Other parameters'),
                    $fragment.Replace('    // Non-required parameters',
                        "    // Non-required parameters`n    // Non-required parameters")
                )) {
                $values = @{
                    examples = ConvertTo-Json -InputObject @{
                        test = @{ JsonParameters = $badFragment }
                    } -Compress -Depth 10
                }
                InModuleScope 'Avm.Authoring' -Parameters @{
                    Values = $values; Rendered = $generated
                } {
                    param($Values, $Rendered)
                    Get-AvmBicepDocsExampleCommentProbe `
                        -Values $Values -GeneratedContent $Rendered |
                        Should -BeNullOrEmpty
                }
            }
        }
    }

    It 'rejects partial or malformed comment-pair omissions and changes to other formats' {
        $generated = New-GroupedExampleReadme
        $requiredOnly = $generated.Replace(
            "  `"parameters`": {`n    // Required parameters`n",
            "  `"parameters`": {`n")
        $optionalOnly = $generated.Replace(
            "    // Non-required parameters`n    `"location`": {",
            '    "location": {')
        $bicepOnly = $generated.Replace(
            "    // Required parameters`n    name: 'demo'",
            "    name: 'demo'")
        $malformedGenerated = $generated.Replace(
            "    // Non-required parameters`n    `"location`": {",
            "    // Non-required parameters`n    // Non-required parameters`n    `"location`": {")
        foreach ($tracked in @($requiredOnly, $optionalOnly, $bicepOnly)) {
            Get-CommentDifferenceCount -Generated $generated -Tracked $tracked |
                Should -Be 0
        }
        Get-CommentDifferenceCount -Generated $malformedGenerated `
            -Tracked (New-GroupedExampleReadme -OmitJsonGroups @(1)) | Should -Be 0
    }

    It 'rejects changes to tracked example context and mismatched private renders' {
        $generated = New-GroupedExampleReadme
        $tracked = New-GroupedExampleReadme -OmitJsonGroups @(1)
        $mutations = @(
            @('## Usage examples', '## Additional guidance'),
            @('### Example 1: _Provision storage_', '### Reference 1: _Provision storage_'),
            @('<summary>via Bicep module</summary>', '<summary>Authored Bicep</summary>'),
            @('<summary>via JSON parameters file</summary>', '<summary>Example JSON</summary>'),
            @('<summary>via Bicep parameters file</summary>', '<summary>Authored parameters</summary>'),
            @('```json', '```jsonc'),
            @('2019-04-01/deploymentParameters.json#', '2019-04-01/otherSchema.json#')
        )
        foreach ($mutation in $mutations) {
            $badTracked = $tracked.Replace($mutation[0], $mutation[1])
            Get-CommentDifferenceCount -Generated $generated -Tracked $badTracked |
                Should -Be 0
        }
        $probe = New-GeneratedExampleProbe -Content $generated
        $probe.Content = $probe.Content.Replace('"value": "demo"', '"value": "other"')
        Get-CommentDifferenceCount -Generated $generated -Tracked $tracked `
            -Provenance $probe | Should -Be 0
    }

    It 'does not mistake a second authored JSON example block for renderer-generated comments' {
        $base = New-GroupedExampleReadme
        $probe = New-GeneratedExampleProbe -Content $base
        $fakeBlock = @'
<details>

<summary>via JSON parameters file</summary>

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    // Required parameters
    "name": {
      "value": "authored"
    },
    // Non-required parameters
    "location": {
      "value": "test"
    }
  }
}
```

</details>
<p>
'@
        $fakeBlock = $fakeBlock.ReplaceLineEndings("`n")
        $trackedBlock = $fakeBlock.Replace("    // Required parameters`n", '')
        $trackedBlock = $trackedBlock.Replace("    // Non-required parameters`n", '')
        $anchor = "### Example 1: _Provision storage_`n`n"
        $tracked = $base.Replace($anchor, $anchor + $trackedBlock + "`n`n")
        $generated = $base.Replace($anchor, $anchor + $fakeBlock + "`n`n")
        $probe.Content = $probe.Content.Replace($anchor, $anchor + $fakeBlock + "`n`n")

        Get-CommentDifferenceCount -Generated $generated -Tracked $tracked `
            -Provenance $probe | Should -Be 0
    }

    It 'rejects authored example frames hidden behind an extra Markdown heading' {
        $base = New-GroupedExampleReadme
        $baseProbe = New-GeneratedExampleProbe -Content $base
        $anchor = "### Example 1: _Provision storage_`n`n"
        $start = $base.IndexOf('<details>', [System.StringComparison]::Ordinal)
        $end = $base.IndexOf("`n`n## Parameters", $start, [System.StringComparison]::Ordinal)
        $frame = $base.Substring($start, $end - $start)
        $jsonStart = $frame.IndexOf('```json', [System.StringComparison]::Ordinal)
        $jsonEnd = $frame.IndexOf("`n" + '```', $jsonStart + 7,
            [System.StringComparison]::Ordinal)
        $json = $frame.Substring($jsonStart, $jsonEnd - $jsonStart)
        $withoutComments = $json.Replace("    // Required parameters`n", '')
        $withoutComments = $withoutComments.Replace("    // Non-required parameters`n", '')
        $withoutComments = $frame.Substring(0, $jsonStart) + $withoutComments +
        $frame.Substring($jsonEnd)
        foreach ($heading in @('### Appendix', '### Example 2: _Authored_', '## Parameters')) {
            $generated = $base.Replace($anchor, $anchor + $frame + "`n`n$heading`n`n")
            $tracked = $base.Replace($anchor, $anchor + $withoutComments + "`n`n$heading`n`n")
            $probe = [pscustomobject]@{
                Content = $baseProbe.Content.Replace(
                    $anchor, $anchor + $frame + "`n`n$heading`n`n")
                Markers = $baseProbe.Markers
            }
            Get-CommentDifferenceCount -Generated $generated -Tracked $tracked `
                -Provenance $probe | Should -Be 0 -Because $heading
        }
    }

    It 'allows real missing comments despite authored full frames and Markdown or HTML boundaries' {
        $base = New-GroupedExampleReadme
        $baseTracked = New-GroupedExampleReadme -OmitJsonGroups @(1)
        $baseProbe = New-GeneratedExampleProbe -Content $base
        $anchor = "### Example 1: _Provision storage_`n`n"
        $start = $base.IndexOf('<details>', [System.StringComparison]::Ordinal)
        $end = $base.IndexOf("`n`n## Parameters", $start, [System.StringComparison]::Ordinal)
        $frame = $base.Substring($start, $end - $start)
        $authored = "### Appendix`n`n$frame`n`n## Local guidance`n`n" +
        "<details>`n<summary>Authored details</summary>`n</details>`n`n"
        $generated = $base.Replace($anchor, $anchor + $authored)
        $tracked = $baseTracked.Replace($anchor, $anchor + $authored)
        $probe = [pscustomobject]@{
            Content = $baseProbe.Content.Replace($anchor, $anchor + $authored)
            Markers = $baseProbe.Markers
        }
        Get-CommentDifferenceCount -Generated $generated -Tracked $tracked `
            -Provenance $probe | Should -Be 2
        $badTracked = $tracked.Replace('### Appendix', '### Different appendix')
        Get-CommentDifferenceCount -Generated $generated -Tracked $badTracked `
            -Provenance $probe | Should -Be 0
    }

    It 'rejects absent, duplicated, or misplaced provenance markers' {
        $generated = New-GroupedExampleReadme
        $tracked = New-GroupedExampleReadme -OmitJsonGroups @(1)
        $probe = New-GeneratedExampleProbe -Content $generated
        $required = $probe.Markers[0].RequiredMarker
        $variations = @(
            $probe.Content.Replace($required, ''),
            $probe.Content.Replace($required, $required + $required),
            $probe.Content.Replace($required + '    // Required parameters',
                '    // Required parameters' + $required)
        )
        foreach ($badProbe in $variations) {
            Get-CommentDifferenceCount -Generated $generated -Tracked $tracked `
                -Provenance ([pscustomobject]@{
                    Content = $badProbe; Markers = $probe.Markers
                }) | Should -Be 0
        }
    }

    It 'does not classify empty, truncated, or invalid UTF-8 input as an exception' {
        $generated = New-GroupedExampleReadme
        $tracked = New-GroupedExampleReadme -OmitJsonGroups @(1)
        Get-CommentDifferenceCount -Generated $generated -Tracked '' | Should -Be 0
        Get-CommentDifferenceCount -Generated '' -Tracked $tracked | Should -Be 0
        Get-CommentDifferenceCount -Generated $generated `
            -Tracked ($tracked.Substring(0, $tracked.Length - 10)) | Should -Be 0

        $probe = New-GeneratedExampleProbe -Content $generated
        InModuleScope 'Avm.Authoring' -Parameters @{
            Generated = $generated; Probe = $probe
        } {
            param($Generated, $Probe)
            Get-AvmBicepDocsExampleCommentDifferenceCount `
                -CurrentBytes ([byte[]]@(0xFF, 0xFE)) -GeneratedContent $Generated `
                -ProbeContent $Probe.Content -Markers $Probe.Markers |
                Should -Be 0
        }
    }
}
