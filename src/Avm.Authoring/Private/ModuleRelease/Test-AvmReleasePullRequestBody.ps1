function Test-AvmReleasePullRequestBody {
    <#
    .SYNOPSIS
        Check the breaking-change structure of a pull request description.

    .DESCRIPTION
        Reads the breaking-changes checkbox and the "What changes" and "Required upgrade" fields from a pull request description. HTML comments are removed first, so template guidance never counts as content. The checkbox and field headings are ignored inside fenced code blocks.

        When the checkbox is ticked, both fields must exist once each and hold text other than a template placeholder. The check validates structure only. It never judges whether the text is accurate. When the description has no checkbox, the pull request declares no breaking change. When it has more than one, the result is ambiguous and invalid.

    .PARAMETER Body
        The pull request description.

    .EXAMPLE
        Test-AvmReleasePullRequestBody -Body "- [x] Breaking changes`n`n### What changes`n`nThe input is removed.`n`n### Required upgrade`n`nUse the new input."

        Returns IsValid $true and BreakingChange $true.

    .OUTPUTS
        Ordered dictionary with IsValid, BreakingChange, CheckboxFound, WhatChanges, RequiredUpgrade, and Issues. Each issue has Code and Message.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Body
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $policy = Get-AvmReleasePolicy
    $issues = [System.Collections.Generic.List[object]]::new()

    $text = ''
    if (-not [string]::IsNullOrEmpty($Body)) {
        $text = $Body -replace "`r`n?", "`n"
        $text = [regex]::Replace($text, '<!--[\s\S]*?(-->|$)', '')
    }

    $checkboxPattern = '^\s*[-*+]\s+\[([ xX])\]\s+' + [regex]::Escape($policy.BreakingCheckbox) + '\.?\s*$'
    $checkboxes = [System.Collections.Generic.List[bool]]::new()
    $fence = $null
    foreach ($line in ($text -split "`n")) {
        $fenceMatch = [regex]::Match($line, '^ {0,3}(`{3,}|~{3,})')
        if ($null -ne $fence) {
            if ($fenceMatch.Success -and $fenceMatch.Groups[1].Value[0] -eq $fence[0] -and $fenceMatch.Groups[1].Value.Length -ge $fence.Length) {
                $fence = $null
            }
            continue
        }
        if ($fenceMatch.Success) {
            $fence = $fenceMatch.Groups[1].Value
            continue
        }
        $match = [regex]::Match($line, $checkboxPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $checkboxes.Add($match.Groups[1].Value -ne ' ')
        }
    }

    $breaking = $checkboxes.Contains($true)
    if ($checkboxes.Count -gt 1) {
        $issues.Add([ordered]@{ Code = 'breaking-checkbox-ambiguous'; Message = "The description has $($checkboxes.Count) breaking-changes checkboxes. Keep exactly one." })
    }

    $sections = (Get-AvmReleaseMarkdownSection -Markdown $text -MaximumLevel 6).Sections
    $fields = [ordered]@{}
    foreach ($field in @(
            @{ Key = 'WhatChanges'; Heading = $policy.WhatChangesHeading; Code = 'what-changes' }
            @{ Key = 'RequiredUpgrade'; Heading = $policy.RequiredUpgradeHeading; Code = 'required-upgrade' }
        )) {
        $found = @($sections | Where-Object { ($_.Heading -replace '\s*:$', '') -eq $field.Heading })
        $value = $null
        if ($found.Count -ge 1) {
            $value = $found[0].Text
        }
        if ($found.Count -gt 1) {
            $issues.Add([ordered]@{ Code = "$($field.Code)-duplicate"; Message = "The description has more than one '$($field.Heading)' heading. Keep exactly one." })
        }
        $isPlaceholder = $null -ne $value -and @($policy.BodyPlaceholders | Where-Object { $_ -eq $value }).Count -gt 0
        if ($breaking) {
            if ($found.Count -eq 0 -or [string]::IsNullOrWhiteSpace($value)) {
                $issues.Add([ordered]@{ Code = "$($field.Code)-missing"; Message = "A breaking change needs a '$($field.Heading)' section with text." })
            }
            elseif ($isPlaceholder) {
                $issues.Add([ordered]@{ Code = "$($field.Code)-placeholder"; Message = "Replace the placeholder text in the '$($field.Heading)' section." })
            }
        }
        if ([string]::IsNullOrWhiteSpace($value) -or $isPlaceholder) {
            $value = $null
        }
        $fields[$field.Key] = $value
    }

    return [ordered]@{
        IsValid         = $issues.Count -eq 0
        BreakingChange  = $breaking
        CheckboxFound   = $checkboxes.Count -gt 0
        WhatChanges     = $fields.WhatChanges
        RequiredUpgrade = $fields.RequiredUpgrade
        Issues          = $issues.ToArray()
    }
}
