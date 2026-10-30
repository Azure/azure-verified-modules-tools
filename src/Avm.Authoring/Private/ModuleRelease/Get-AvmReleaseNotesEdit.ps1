function Get-AvmReleaseNotesEdit {
    <#
    .SYNOPSIS
        Validate a #ReleaseNotes comment and work out which release-notes text it replaces.

    .DESCRIPTION
        Reads the Markdown that follows #ReleaseNotes. Text without level-1 or level-2 headings is maintainer commentary. Otherwise the text must hold only the 'Breaking changes' and 'Notes from maintainers' sections, each at most once, with nothing before the first heading. Deeper headings stay inside their section. The change list cannot be edited.

        A section equal to the text the release currently uses changes nothing. An empty or placeholder 'Notes from maintainers' section clears the commentary. A changed 'Breaking changes' section becomes an override. The override must not be empty, and it must mention every declared breaking pull request as '#number'. A comment that changes nothing is rejected.

    .PARAMETER Markdown
        The Markdown after the #ReleaseNotes command.

    .PARAMETER CurrentCommentary
        The commentary the pending release uses now, or null.

    .PARAMETER CurrentBreakingText
        The breaking-changes text the pending release uses now, or null.

    .PARAMETER DeclaredBreakingPullRequests
        The numbers of pending pull requests that declare a breaking change.

    .EXAMPLE
        Get-AvmReleaseNotesEdit -Markdown 'This release adds private endpoints.' -CurrentCommentary $null -CurrentBreakingText $null -DeclaredBreakingPullRequests @()

        Returns Accepted $true and the new commentary.

    .OUTPUTS
        Ordered dictionary with Accepted, Error, Message, CommentaryChanged, Commentary, BreakingChanged, BreakingOverride, and CoveredPullRequests.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Markdown,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $CurrentCommentary,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $CurrentBreakingText,

        [AllowNull()]
        [AllowEmptyCollection()]
        [int[]] $DeclaredBreakingPullRequests = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $policy = Get-AvmReleasePolicy
    $declared = @($DeclaredBreakingPullRequests | Where-Object { $null -ne $_ } | Sort-Object -Unique)
    $currentCommentaryText = ConvertTo-AvmReleaseNormalizedText -Text $CurrentCommentary
    $currentBreaking = ConvertTo-AvmReleaseNormalizedText -Text $CurrentBreakingText

    $result = [ordered]@{
        Accepted            = $false
        Error               = $null
        Message             = $null
        CommentaryChanged   = $false
        Commentary          = $null
        BreakingChanged     = $false
        BreakingOverride    = $null
        CoveredPullRequests = @()
    }

    $reject = {
        param([string] $Code, [string] $Message)
        $result.Error = $Code
        $result.Message = $Message
        return $result
    }

    $text = ConvertTo-AvmReleaseNormalizedText -Text $Markdown
    if ($text.Length -eq 0) {
        return & $reject -Code 'empty' -Message 'The #ReleaseNotes comment has no text.'
    }

    $parsed = Get-AvmReleaseMarkdownSection -Markdown $text -MaximumLevel 2
    $commentary = $null
    $hasCommentary = $false
    $breaking = $null
    $hasBreaking = $false
    if ($parsed.Sections.Count -eq 0) {
        $commentary = $parsed.Preamble
        $hasCommentary = $true
    }
    else {
        if ($parsed.Preamble.Length -gt 0) {
            return & $reject -Code 'text-before-heading' -Message "Put all text under a '## $($policy.BreakingHeading)' or '## $($policy.CommentaryHeading)' heading."
        }
        foreach ($section in $parsed.Sections) {
            if ($section.Heading -eq $policy.CommentaryHeading) {
                if ($hasCommentary) {
                    return & $reject -Code 'duplicate-section' -Message "The '$($policy.CommentaryHeading)' section appears more than once."
                }
                $hasCommentary = $true
                $commentary = $section.Text
            }
            elseif ($section.Heading -eq $policy.BreakingHeading) {
                if ($hasBreaking) {
                    return & $reject -Code 'duplicate-section' -Message "The '$($policy.BreakingHeading)' section appears more than once."
                }
                $hasBreaking = $true
                $breaking = $section.Text
            }
            elseif ($section.Heading -eq $policy.ChangesHeading) {
                return & $reject -Code 'change-list-not-editable' -Message "The '$($policy.ChangesHeading)' list comes from merged pull requests and cannot be edited."
            }
            else {
                return & $reject -Code 'unknown-section' -Message "Unknown section '$($section.Heading)'. Use '$($policy.BreakingHeading)' or '$($policy.CommentaryHeading)'."
            }
        }
    }

    if ($hasCommentary) {
        $newCommentary = $commentary
        if ($newCommentary -eq $policy.CommentaryPlaceholder) {
            $newCommentary = ''
        }
        if ($newCommentary -cne $currentCommentaryText) {
            $result.CommentaryChanged = $true
            if ($newCommentary.Length -gt 0) {
                $result.Commentary = $newCommentary
            }
        }
    }

    if ($hasBreaking -and $breaking -cne $currentBreaking) {
        if ($breaking.Length -eq 0) {
            return & $reject -Code 'empty-breaking-changes' -Message "The '$($policy.BreakingHeading)' section cannot be empty. Known breaking changes must stay visible."
        }
        $mentioned = @([regex]::Matches($breaking, '#(\d+)\b') | ForEach-Object { [int]$_.Groups[1].Value })
        $missing = @($declared | Where-Object { $mentioned -notcontains $_ })
        if ($missing.Count -gt 0) {
            $list = ($missing | ForEach-Object { "#$_" }) -join ', '
            return & $reject -Code 'missing-breaking-pull-request' -Message "The '$($policy.BreakingHeading)' section must mention every declared breaking pull request. Missing: $list."
        }
        $result.BreakingChanged = $true
        $result.BreakingOverride = $breaking
        $result.CoveredPullRequests = [int[]]$declared
    }

    if (-not $result.CommentaryChanged -and -not $result.BreakingChanged) {
        return & $reject -Code 'no-change' -Message 'The #ReleaseNotes comment does not change the release notes.'
    }

    $result.Accepted = $true
    return $result
}
