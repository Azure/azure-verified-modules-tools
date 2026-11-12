@{
    Area      = 'notes'
    Function  = 'Format-AvmReleaseNotes'
    Scenarios = @(
        @{
            Id       = 'notes-01'
            Title    = 'The design example composes breaking changes, commentary, the change list, and the link'
            Design   = 'Editing release notes on the release issue: the v0.9.0 preview'
            Input    = @{
                BreakingEntries  = @(
                    @{
                        Number          = 142
                        WhatChanges     = 'The `subnet_id` input is removed, so configurations that set it fail to plan.'
                        RequiredUpgrade = 'Replace `subnet_id` with `subnet_resource_id`.'
                    }
                )
                BreakingOverride = $null
                Commentary       = 'This release prepares the module for shared network inputs.'
                Changes          = @(
                    @{ Number = 145; Title = 'fix: correct the default SKU' }
                    @{ Number = 142; Title = 'feat!: replace `subnet_id` with `subnet_resource_id`' }
                )
                Repository       = 'Azure/terraform-azurerm-avm-res-example'
                PreviousVersion  = '0.8.2'
                Version          = '0.9.0'
            }
            Expected = @{
                Markdown                 = @'
## Breaking changes

- **What changes:** The `subnet_id` input is removed, so configurations that set it fail to plan. (#142)
- **Required upgrade:** Replace `subnet_id` with `subnet_resource_id`.

## Notes from maintainers

This release prepares the module for shared network inputs.

## What's changed

- feat!: replace `subnet_id` with `subnet_resource_id` (#142)
- fix: correct the default SKU (#145)

**Full changelog:** https://github.com/Azure/terraform-azurerm-avm-res-example/compare/v0.8.2...v0.9.0

'@
                BreakingText             = @'
- **What changes:** The `subnet_id` input is removed, so configurations that set it fail to plan. (#142)
- **Required upgrade:** Replace `subnet_id` with `subnet_resource_id`.
'@
                LateBreakingPullRequests = @()
            }
        }
        @{
            Id       = 'notes-02'
            Title    = 'A late breaking PR is appended below the override'
            Design   = 'Overriding the breaking changes: late breaking PRs are appended below the override'
            Input    = @{
                BreakingEntries  = @(
                    @{
                        Number          = 150
                        WhatChanges     = 'The `sku` default changes to Standard.'
                        RequiredUpgrade = 'Set `sku = "Basic"` to keep the old default.'
                    }
                    @{
                        Number          = 142
                        WhatChanges     = 'The `subnet_id` input is removed, so configurations that set it fail to plan.'
                        RequiredUpgrade = 'Replace `subnet_id` with `subnet_resource_id`.'
                    }
                )
                BreakingOverride = @{
                    Text                = '- #142 renames the subnet input to `subnet_resource_id`.'
                    CoveredPullRequests = @(142)
                }
                Repository       = 'Azure/terraform-azurerm-avm-res-example'
            }
            Expected = @{
                Markdown                 = @'
## Breaking changes

- #142 renames the subnet input to `subnet_resource_id`.

- **What changes:** The `sku` default changes to Standard. (#150)
- **Required upgrade:** Set `sku = "Basic"` to keep the old default.

'@
                LateBreakingPullRequests = @(150)
            }
        }
        @{
            Id       = 'notes-03'
            Title    = 'An override that covers every breaking PR replaces the entries'
            Design   = 'Overriding the breaking changes'
            Input    = @{
                BreakingEntries  = @(
                    @{ Number = 142; WhatChanges = 'Removed.'; RequiredUpgrade = 'Replace it.' }
                )
                BreakingOverride = @{
                    Text                = '- #142 renames the subnet input.'
                    CoveredPullRequests = @(142)
                }
                Repository       = 'Azure/terraform-azurerm-avm-res-example'
            }
            Expected = @{
                BreakingText             = '- #142 renames the subnet input.'
                LateBreakingPullRequests = @()
            }
        }
        @{
            Id         = 'notes-04'
            Title      = 'Missing breaking details are shown as not provided'
            Design     = 'Breaking-change details: known breaking changes must remain visible'
            Assumption = 'A breaking entry with a missing field still appears, with a visible _Not provided._ marker. The metadata check blocks such a PR separately.'
            Input      = @{
                BreakingEntries = @(
                    @{ Number = 150; WhatChanges = $null; RequiredUpgrade = '' }
                )
                Repository      = 'Azure/terraform-azurerm-avm-res-example'
            }
            Expected   = @{
                BreakingText = @'
- **What changes:** _Not provided._ (#150)
- **Required upgrade:** _Not provided._
'@
            }
        }
        @{
            Id       = 'notes-05'
            Title    = 'Multi-line breaking details stay inside their list item'
            Design   = 'Composing release notes: the same format for every entry'
            Input    = @{
                BreakingEntries = @(
                    @{
                        Number          = 150
                        WhatChanges     = @'
The `sku` default changes.

Existing deployments are recreated.
'@
                        RequiredUpgrade = 'Pin `sku`.'
                    }
                )
                Repository      = 'Azure/terraform-azurerm-avm-res-example'
            }
            Expected = @{
                BreakingText = @'
- **What changes:** The `sku` default changes.

  Existing deployments are recreated. (#150)
- **Required upgrade:** Pin `sku`.
'@
            }
        }
        @{
            Id       = 'notes-06'
            Title    = 'Breaking entries are sorted by PR number'
            Design   = 'Composing release notes: one combined list'
            Input    = @{
                BreakingEntries = @(
                    @{ Number = 150; WhatChanges = 'B.'; RequiredUpgrade = 'Do B.' }
                    @{ Number = 142; WhatChanges = 'A.'; RequiredUpgrade = 'Do A.' }
                )
                Repository      = 'Azure/terraform-azurerm-avm-res-example'
            }
            Expected = @{
                BreakingText = @'
- **What changes:** A. (#142)
- **Required upgrade:** Do A.

- **What changes:** B. (#150)
- **Required upgrade:** Do B.
'@
            }
        }
        @{
            Id       = 'notes-07'
            Title    = 'Nothing to say gives empty notes'
            Design   = 'Composing release notes'
            Input    = @{
                Repository = 'Azure/terraform-azurerm-avm-res-example'
            }
            Expected = @{
                Markdown                 = ''
                BreakingText             = ''
                LateBreakingPullRequests = @()
            }
        }
        @{
            Id       = 'notes-08'
            Title    = 'An unknown version leaves out the comparison link'
            Design   = 'Composing release notes: a comparison link covers the complete changes'
            Input    = @{
                Changes         = @(
                    @{ Number = 145; Title = 'fix: correct the default SKU' }
                )
                Repository      = 'Azure/terraform-azurerm-avm-res-example'
                PreviousVersion = '0.8.2'
                Version         = $null
            }
            Expected = @{
                Markdown = @'
## What's changed

- fix: correct the default SKU (#145)

'@
            }
        }
        @{
            Id       = 'notes-09'
            Title    = 'Change titles are collapsed to one line and sorted by number'
            Design   = 'Composing release notes: the change list'
            Input    = @{
                Changes    = @(
                    @{
                        Number = 147
                        Title  = @'
fix: first
  line
'@
                    }
                    @{ Number = 143; Title = 'docs: clarify' }
                )
                Repository = 'Azure/terraform-azurerm-avm-res-example'
            }
            Expected = @{
                Markdown = @'
## What's changed

- docs: clarify (#143)
- fix: first line (#147)

'@
            }
        }
        @{
            Id       = 'notes-10'
            Title    = 'Commentary alone produces a commentary section'
            Design   = 'Composing release notes: maintainer commentary is optional'
            Input    = @{
                Commentary = 'This release adds private endpoints.   '
                Repository = 'Azure/terraform-azurerm-avm-res-example'
            }
            Expected = @{
                Markdown = @'
## Notes from maintainers

This release adds private endpoints.

'@
            }
        }
    )
}
