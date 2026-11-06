function Get-AvmReleaseMarkdownSection {
    <#
    .SYNOPSIS
        Split Markdown into the text before the first heading and one section per heading.

    .DESCRIPTION
        Walks the Markdown line by line and splits it at ATX headings (one to six '#' characters followed by a space) whose level is at most MaximumLevel. Headings inside fenced code blocks are ignored. Deeper headings stay inside the section text. The preamble and each section's text are normalised with ConvertTo-AvmReleaseNormalizedText.

    .PARAMETER Markdown
        The Markdown to split.

    .PARAMETER MaximumLevel
        The deepest heading level that starts a new section.

    .EXAMPLE
        Get-AvmReleaseMarkdownSection -Markdown "## Breaking changes`n`nText" -MaximumLevel 2

        Returns an empty preamble and one section with Heading 'Breaking changes' and Text 'Text'.

    .OUTPUTS
        Ordered dictionary with Preamble (string) and Sections (array of ordered dictionaries with Heading, Level, and Text).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Markdown,

        [ValidateRange(1, 6)]
        [int] $MaximumLevel = 6
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $lines = @()
    if (-not [string]::IsNullOrEmpty($Markdown)) {
        $lines = @(($Markdown -replace "`r`n?", "`n") -split "`n")
    }

    $preamble = [System.Collections.Generic.List[string]]::new()
    $sections = [System.Collections.Generic.List[object]]::new()
    $current = $preamble
    $fence = $null
    foreach ($line in $lines) {
        $fenceMatch = [regex]::Match($line, '^ {0,3}(`{3,}|~{3,})')
        if ($null -ne $fence) {
            if ($fenceMatch.Success -and $fenceMatch.Groups[1].Value[0] -eq $fence[0] -and $fenceMatch.Groups[1].Value.Length -ge $fence.Length) {
                $fence = $null
            }
            $current.Add($line)
            continue
        }
        if ($fenceMatch.Success) {
            $fence = $fenceMatch.Groups[1].Value
            $current.Add($line)
            continue
        }

        $heading = [regex]::Match($line, '^ {0,3}(#{1,6})(?:[ \t]+(.*))?$')
        if ($heading.Success -and $heading.Groups[1].Value.Length -le $MaximumLevel) {
            $text = $heading.Groups[2].Value.Trim()
            $text = ($text -replace '(^|[ \t]+)#+$', '').Trim()
            $section = @{
                Heading = $text
                Level   = $heading.Groups[1].Value.Length
                Lines   = [System.Collections.Generic.List[string]]::new()
            }
            $sections.Add($section)
            $current = $section.Lines
            continue
        }

        $current.Add($line)
    }

    $output = [System.Collections.Generic.List[object]]::new()
    foreach ($section in $sections) {
        $output.Add([ordered]@{
                Heading = $section.Heading
                Level   = $section.Level
                Text    = ConvertTo-AvmReleaseNormalizedText -Text ($section.Lines -join "`n")
            })
    }

    return [ordered]@{
        Preamble = ConvertTo-AvmReleaseNormalizedText -Text ($preamble -join "`n")
        Sections = $output.ToArray()
    }
}
