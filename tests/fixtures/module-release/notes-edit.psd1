@{
    Area      = 'notes-edit'
    Function  = 'Get-AvmReleaseNotesEdit'
    Scenarios = @(
        @{
            Id       = 'notes-edit-01'
            Title    = 'Plain text becomes maintainer commentary'
            Design   = 'Composing release notes: maintainer commentary comes from a #ReleaseNotes comment'
            Input    = @{
                Markdown                     = 'This release adds private endpoints.'
                CurrentCommentary            = $null
                CurrentBreakingText          = $null
                DeclaredBreakingPullRequests = @()
            }
            Expected = @{
                Accepted          = $true
                Error             = $null
                CommentaryChanged = $true
                Commentary        = 'This release adds private endpoints.'
                BreakingChanged   = $false
                BreakingOverride  = $null
            }
        }
        @{
            Id       = 'notes-edit-02'
            Title    = 'The design example adds commentary and keeps the breaking changes'
            Design   = 'Editing release notes on the release issue: here, they only add commentary'
            Input    = @{
                Markdown                     = @'
## Breaking changes

- **What changes:** The `subnet_id` input is removed, so configurations that set it fail to plan. (#142)
- **Required upgrade:** Replace `subnet_id` with `subnet_resource_id`.

## Notes from maintainers

This release prepares the module for shared network inputs.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = @'
- **What changes:** The `subnet_id` input is removed, so configurations that set it fail to plan. (#142)
- **Required upgrade:** Replace `subnet_id` with `subnet_resource_id`.
'@
                DeclaredBreakingPullRequests = @(142)
            }
            Expected = @{
                Accepted          = $true
                CommentaryChanged = $true
                Commentary        = 'This release prepares the module for shared network inputs.'
                BreakingChanged   = $false
                BreakingOverride  = $null
            }
        }
        @{
            Id       = 'notes-edit-03'
            Title    = 'Posting the copy block unchanged is rejected'
            Design   = 'Editing release notes on the release issue: the bot rejects a comment that changes nothing'
            Input    = @{
                Markdown                     = @'
## Breaking changes

- **What changes:** The `subnet_id` input is removed, so configurations that set it fail to plan. (#142)
- **Required upgrade:** Replace `subnet_id` with `subnet_resource_id`.

## Notes from maintainers

Replace this line with a short summary for users.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = @'
- **What changes:** The `subnet_id` input is removed, so configurations that set it fail to plan. (#142)
- **Required upgrade:** Replace `subnet_id` with `subnet_resource_id`.
'@
                DeclaredBreakingPullRequests = @(142)
            }
            Expected = @{
                Accepted = $false
                Error    = 'no-change'
                Message  = 'The #ReleaseNotes comment does not change the release notes.'
            }
        }
        @{
            Id         = 'notes-edit-04'
            Title      = 'The placeholder clears existing commentary'
            Design     = 'Editing release notes on the release issue: an unchanged placeholder stores no commentary'
            Assumption = 'Because the latest accepted command replaces earlier text, posting the placeholder over existing commentary removes that commentary.'
            Input      = @{
                Markdown                     = @'
## Notes from maintainers

Replace this line with a short summary for users.
'@
                CurrentCommentary            = 'Old commentary.'
                CurrentBreakingText          = $null
                DeclaredBreakingPullRequests = @()
            }
            Expected   = @{
                Accepted          = $true
                CommentaryChanged = $true
                Commentary        = $null
            }
        }
        @{
            Id       = 'notes-edit-05'
            Title    = 'A placeholder with no commentary to clear changes nothing'
            Design   = 'Editing release notes on the release issue: an unchanged placeholder stores no commentary'
            Input    = @{
                Markdown                     = 'Replace this line with a short summary for users.'
                CurrentCommentary            = $null
                CurrentBreakingText          = $null
                DeclaredBreakingPullRequests = @()
            }
            Expected = @{
                Accepted = $false
                Error    = 'no-change'
            }
        }
        @{
            Id       = 'notes-edit-06'
            Title    = 'A shortened override that still mentions the declared PR is accepted'
            Design   = 'Editing release notes on the release issue: shorten the entry as long as it still mentions #142'
            Input    = @{
                Markdown                     = @'
## Breaking changes

- #142 renames `subnet_id` to `subnet_resource_id`.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = '- **What changes:** Removed. (#142)'
                DeclaredBreakingPullRequests = @(142)
            }
            Expected = @{
                Accepted            = $true
                CommentaryChanged   = $false
                BreakingChanged     = $true
                BreakingOverride    = '- #142 renames `subnet_id` to `subnet_resource_id`.'
                CoveredPullRequests = @(142)
            }
        }
        @{
            Id       = 'notes-edit-07'
            Title    = 'An override that drops a declared PR is rejected'
            Design   = 'Overriding the breaking changes: the bot rejects an override that leaves out a declared PR number'
            Input    = @{
                Markdown                     = @'
## Breaking changes

- The subnet input is renamed.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = '- **What changes:** Removed. (#142)'
                DeclaredBreakingPullRequests = @(142)
            }
            Expected = @{
                Accepted = $false
                Error    = 'missing-breaking-pull-request'
                Message  = "The 'Breaking changes' section must mention every declared breaking pull request. Missing: #142."
            }
        }
        @{
            Id       = 'notes-edit-08'
            Title    = 'A longer number does not count as a mention of a declared PR'
            Design   = 'Overriding the breaking changes: no hiding'
            Input    = @{
                Markdown                     = @'
## Breaking changes

- #1420 renames the subnet input.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = '- **What changes:** Removed. (#142)'
                DeclaredBreakingPullRequests = @(142)
            }
            Expected = @{
                Accepted = $false
                Error    = 'missing-breaking-pull-request'
            }
        }
        @{
            Id       = 'notes-edit-09'
            Title    = 'An override must mention every declared PR'
            Design   = 'Overriding the breaking changes: no hiding'
            Input    = @{
                Markdown                     = @'
## Breaking changes

- #142 renames the subnet input.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = '- Current text for #142 and #150.'
                DeclaredBreakingPullRequests = @(150, 142)
            }
            Expected = @{
                Accepted = $false
                Error    = 'missing-breaking-pull-request'
                Message  = "The 'Breaking changes' section must mention every declared breaking pull request. Missing: #150."
            }
        }
        @{
            Id       = 'notes-edit-10'
            Title    = 'An empty breaking-changes section is rejected'
            Design   = 'Overriding the breaking changes: the bot rejects an override that is empty'
            Input    = @{
                Markdown                     = @'
## Breaking changes

## Notes from maintainers

Some commentary.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = '- **What changes:** Removed. (#142)'
                DeclaredBreakingPullRequests = @(142)
            }
            Expected = @{
                Accepted = $false
                Error    = 'empty-breaking-changes'
            }
        }
        @{
            Id       = 'notes-edit-11'
            Title    = 'Text before the first section heading is rejected'
            Design   = 'Editing release notes on the release issue: the bot finds sections by heading'
            Input    = @{
                Markdown                     = @'
Some intro.

## Notes from maintainers

Text.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = $null
                DeclaredBreakingPullRequests = @()
            }
            Expected = @{
                Accepted = $false
                Error    = 'text-before-heading'
            }
        }
        @{
            Id       = 'notes-edit-12'
            Title    = 'A repeated section is rejected'
            Design   = 'Editing release notes on the release issue'
            Input    = @{
                Markdown                     = @'
## Notes from maintainers

One.

## Notes from maintainers

Two.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = $null
                DeclaredBreakingPullRequests = @()
            }
            Expected = @{
                Accepted = $false
                Error    = 'duplicate-section'
                Message  = "The 'Notes from maintainers' section appears more than once."
            }
        }
        @{
            Id       = 'notes-edit-13'
            Title    = 'The change list cannot be edited'
            Design   = 'Editing release notes on the release issue: the command cannot remove the change list'
            Input    = @{
                Markdown                     = @'
## What's changed

- Nothing.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = $null
                DeclaredBreakingPullRequests = @()
            }
            Expected = @{
                Accepted = $false
                Error    = 'change-list-not-editable'
            }
        }
        @{
            Id       = 'notes-edit-14'
            Title    = 'An unknown section is rejected'
            Design   = 'Editing release notes on the release issue: two sections, found by heading'
            Input    = @{
                Markdown                     = @'
## Summary

Text.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = $null
                DeclaredBreakingPullRequests = @()
            }
            Expected = @{
                Accepted = $false
                Error    = 'unknown-section'
                Message  = "Unknown section 'Summary'. Use 'Breaking changes' or 'Notes from maintainers'."
            }
        }
        @{
            Id       = 'notes-edit-15'
            Title    = 'An empty #ReleaseNotes is rejected'
            Design   = 'Editing release notes on the release issue'
            Input    = @{
                Markdown                     = ''
                CurrentCommentary            = 'Existing.'
                CurrentBreakingText          = $null
                DeclaredBreakingPullRequests = @()
            }
            Expected = @{
                Accepted = $false
                Error    = 'empty'
                Message  = 'The #ReleaseNotes comment has no text.'
            }
        }
        @{
            Id         = 'notes-edit-16'
            Title      = 'Text with only deeper headings is commentary'
            Design     = 'Editing release notes on the release issue'
            Assumption = 'Only level-1 and level-2 headings start sections. A comment with only deeper headings is commentary, so maintainers can structure it.'
            Input      = @{
                Markdown                     = @'
### Highlights

- Faster plans.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = $null
                DeclaredBreakingPullRequests = @()
            }
            Expected   = @{
                Accepted   = $true
                Commentary = @'
### Highlights

- Faster plans.
'@
            }
        }
        @{
            Id       = 'notes-edit-17'
            Title    = 'A level-1 section heading is accepted'
            Design   = 'Editing release notes on the release issue'
            Input    = @{
                Markdown                     = @'
# Notes from maintainers

Text.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = $null
                DeclaredBreakingPullRequests = @()
            }
            Expected = @{
                Accepted   = $true
                Commentary = 'Text.'
            }
        }
        @{
            Id       = 'notes-edit-18'
            Title    = 'Changing only the breaking section leaves commentary alone'
            Design   = 'Editing release notes on the release issue: a section left unchanged keeps what the release currently uses'
            Input    = @{
                Markdown                     = @'
## Breaking changes

- #142 renames the subnet input.

## Notes from maintainers

Existing commentary.
'@
                CurrentCommentary            = 'Existing commentary.'
                CurrentBreakingText          = '- **What changes:** Removed. (#142)'
                DeclaredBreakingPullRequests = @(142)
            }
            Expected = @{
                Accepted          = $true
                CommentaryChanged = $false
                Commentary        = $null
                BreakingChanged   = $true
            }
        }
        @{
            Id         = 'notes-edit-19'
            Title      = 'A breaking-changes section is accepted when no PR declared one'
            Design     = 'Breaking-change details: honor system'
            Assumption = 'A maintainer can add a breaking-changes section for a change no PR declared. It covers no PRs.'
            Input      = @{
                Markdown                     = @'
## Breaking changes

- The default SKU changed in #145.
'@
                CurrentCommentary            = $null
                CurrentBreakingText          = $null
                DeclaredBreakingPullRequests = @()
            }
            Expected   = @{
                Accepted            = $true
                BreakingChanged     = $true
                BreakingOverride    = '- The default SKU changed in #145.'
                CoveredPullRequests = @()
            }
        }
    )
}
