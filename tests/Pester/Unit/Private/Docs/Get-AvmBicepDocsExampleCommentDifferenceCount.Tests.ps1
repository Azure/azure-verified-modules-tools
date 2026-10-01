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

    function Get-CommentDifferenceCount {
        param(
            [AllowEmptyString()][string] $Generated,
            [AllowEmptyString()][string] $Tracked
        )

        $bytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($Tracked)
        InModuleScope 'Avm.Authoring' -Parameters @{ Bytes = $bytes; Text = $Generated } {
            param($Bytes, $Text)
            Get-AvmBicepDocsExampleCommentDifferenceCount `
                -CurrentBytes $Bytes -GeneratedContent $Text
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

    It 'requires the exact labeled JSON fence, deployment schema, and example section' {
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
            $badGenerated = $generated.Replace($mutation[0], $mutation[1])
            $badTracked = $tracked.Replace($mutation[0], $mutation[1])
            Get-CommentDifferenceCount -Generated $badGenerated -Tracked $badTracked |
                Should -Be 0
        }
    }

    It 'does not mistake a second authored JSON example block for renderer-generated comments' {
        $generated = New-GroupedExampleReadme
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
        $tracked = $generated.Replace($anchor, $anchor + $trackedBlock + "`n`n")
        $generated = $generated.Replace($anchor, $anchor + $fakeBlock + "`n`n")

        Get-CommentDifferenceCount -Generated $generated -Tracked $tracked | Should -Be 0
    }

    It 'rejects authored example frames hidden behind an extra Markdown heading' {
        $base = New-GroupedExampleReadme
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
            Get-CommentDifferenceCount -Generated $generated -Tracked $tracked |
                Should -Be 0 -Because $heading
        }
    }

    It 'does not classify empty, truncated, or invalid UTF-8 input as an exception' {
        $generated = New-GroupedExampleReadme
        $tracked = New-GroupedExampleReadme -OmitJsonGroups @(1)
        Get-CommentDifferenceCount -Generated $generated -Tracked '' | Should -Be 0
        Get-CommentDifferenceCount -Generated '' -Tracked $tracked | Should -Be 0
        Get-CommentDifferenceCount -Generated $generated `
            -Tracked ($tracked.Substring(0, $tracked.Length - 10)) | Should -Be 0

        InModuleScope 'Avm.Authoring' -Parameters @{ Generated = $generated } {
            param($Generated)
            Get-AvmBicepDocsExampleCommentDifferenceCount `
                -CurrentBytes ([byte[]]@(0xFF, 0xFE)) -GeneratedContent $Generated |
                Should -Be 0
        }
    }
}
