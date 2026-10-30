@{
    Area      = 'pull-request-body'
    Function  = 'Test-AvmReleasePullRequestBody'
    Scenarios = @(
        @{
            Id       = 'body-01'
            Title    = 'A ticked checkbox with both fields filled in is valid'
            Design   = 'Breaking changes: the PR template has a checkbox, What changes, and Required upgrade'
            Input    = @{
                Body = @'
## Description

Replace the subnet input.

- [x] Breaking changes

### What changes

The `subnet_id` input is removed, so configurations that set it fail to plan.

### Required upgrade

Replace `subnet_id` with `subnet_resource_id`.
'@
            }
            Expected = @{
                IsValid         = $true
                BreakingChange  = $true
                CheckboxFound   = $true
                WhatChanges     = 'The `subnet_id` input is removed, so configurations that set it fail to plan.'
                RequiredUpgrade = 'Replace `subnet_id` with `subnet_resource_id`.'
                Issues          = @()
            }
        }
        @{
            Id       = 'body-02'
            Title    = 'The unticked template is valid and declares no breaking change'
            Design   = 'Breaking changes'
            Input    = @{
                Body = @'
## Description

Fix the default SKU.

- [ ] Breaking changes

### What changes

Describe what breaks for consumers.

### Required upgrade

Describe what consumers must change.
'@
            }
            Expected = @{
                IsValid         = $true
                BreakingChange  = $false
                CheckboxFound   = $true
                WhatChanges     = $null
                RequiredUpgrade = $null
                Issues          = @()
            }
        }
        @{
            Id       = 'body-03'
            Title    = 'A ticked checkbox with unchanged placeholders is invalid'
            Design   = 'Breaking changes: reject unchanged placeholders'
            Input    = @{
                Body = @'
- [x] Breaking changes

### What changes

Describe what breaks for consumers.

### Required upgrade

Describe what consumers must change.
'@
            }
            Expected = @{
                IsValid         = $false
                BreakingChange  = $true
                WhatChanges     = $null
                RequiredUpgrade = $null
                Issues          = @(
                    @{ Code = 'what-changes-placeholder' }
                    @{ Code = 'required-upgrade-placeholder' }
                )
            }
        }
        @{
            Id       = 'body-04'
            Title    = 'HTML comment guidance alone does not fill a field'
            Design   = 'Breaking changes: structure only, and template guidance is not content'
            Input    = @{
                Body = @'
- [x] Breaking changes

### What changes

<!-- Describe what breaks for consumers. -->

### Required upgrade

<!-- Describe what consumers must change. -->
'@
            }
            Expected = @{
                IsValid = $false
                Issues  = @(
                    @{ Code = 'what-changes-missing'; Message = "A breaking change needs a 'What changes' section with text." }
                    @{ Code = 'required-upgrade-missing'; Message = "A breaking change needs a 'Required upgrade' section with text." }
                )
            }
        }
        @{
            Id       = 'body-05'
            Title    = 'A ticked checkbox without the field headings is invalid'
            Design   = 'Breaking changes'
            Input    = @{
                Body = @'
- [x] Breaking changes

This removes `subnet_id`.
'@
            }
            Expected = @{
                IsValid        = $false
                BreakingChange = $true
                WhatChanges    = $null
                Issues         = @(
                    @{ Code = 'what-changes-missing' }
                    @{ Code = 'required-upgrade-missing' }
                )
            }
        }
        @{
            Id         = 'body-06'
            Title      = 'A description without the checkbox declares no breaking change'
            Design     = 'Breaking changes'
            Assumption = 'A missing checkbox means no breaking change is declared. The structure check does not require the template.'
            Input      = @{ Body = 'Fixes the default SKU.' }
            Expected   = @{
                IsValid        = $true
                BreakingChange = $false
                CheckboxFound  = $false
                Issues         = @()
            }
        }
        @{
            Id       = 'body-07'
            Title    = 'Two checkboxes are ambiguous'
            Design   = 'Breaking changes: structure only'
            Input    = @{
                Body = @'
- [ ] Breaking changes
- [x] Breaking changes

### What changes

The input is removed.

### Required upgrade

Use the new input.
'@
            }
            Expected = @{
                IsValid        = $false
                BreakingChange = $true
                Issues         = @(
                    @{ Code = 'breaking-checkbox-ambiguous'; Message = 'The description has 2 breaking-changes checkboxes. Keep exactly one.' }
                )
            }
        }
        @{
            Id       = 'body-08'
            Title    = 'A duplicated field heading is invalid even without a breaking change'
            Design   = 'Breaking changes: structure only'
            Input    = @{
                Body = @'
- [ ] Breaking changes

### What changes

First.

### What changes

Second.
'@
            }
            Expected = @{
                IsValid        = $false
                BreakingChange = $false
                WhatChanges    = 'First.'
                Issues         = @(
                    @{ Code = 'what-changes-duplicate' }
                )
            }
        }
        @{
            Id       = 'body-09'
            Title    = 'A checkbox inside a code fence is ignored'
            Design   = 'Breaking changes: structure only'
            Input    = @{
                Body = @'
Example of the template:

```markdown
- [x] Breaking changes
```
'@
            }
            Expected = @{
                IsValid        = $true
                BreakingChange = $false
                CheckboxFound  = $false
            }
        }
        @{
            Id       = 'body-10'
            Title    = 'A checkbox inside an HTML comment is ignored'
            Design   = 'Breaking changes: structure only'
            Input    = @{
                Body = @'
<!-- Tick this when the change breaks consumers: - [x] Breaking changes -->
- [ ] Breaking changes
'@
            }
            Expected = @{
                IsValid        = $true
                BreakingChange = $false
                CheckboxFound  = $true
                Issues         = @()
            }
        }
        @{
            Id       = 'body-11'
            Title    = 'Field headings match at any level, in any case, with a trailing colon'
            Design   = 'Breaking changes: structure only'
            Input    = @{
                Body = @'
- [x] Breaking changes

#### what changes:

The input is removed.

#### REQUIRED UPGRADE

Use the new input.
'@
            }
            Expected = @{
                IsValid         = $true
                WhatChanges     = 'The input is removed.'
                RequiredUpgrade = 'Use the new input.'
            }
        }
        @{
            Id       = 'body-12'
            Title    = 'The checkbox accepts a capital X, an asterisk bullet, and a trailing period'
            Design   = 'Breaking changes'
            Input    = @{
                Body = @'
* [X] Breaking changes.

### What changes

The input is removed.

### Required upgrade

Use the new input.
'@
            }
            Expected = @{
                IsValid        = $true
                BreakingChange = $true
            }
        }
        @{
            Id       = 'body-13'
            Title    = 'An empty description is valid and declares no breaking change'
            Design   = 'Breaking changes'
            Input    = @{ Body = '' }
            Expected = @{
                IsValid         = $true
                BreakingChange  = $false
                CheckboxFound   = $false
                WhatChanges     = $null
                RequiredUpgrade = $null
                Issues          = @()
            }
        }
        @{
            Id       = 'body-14'
            Title    = 'One filled field and one placeholder report only the placeholder'
            Design   = 'Breaking changes: reject unchanged placeholders'
            Input    = @{
                Body = @'
- [x] Breaking changes

### What changes

The input is removed.

### Required upgrade

Describe what consumers must change.
'@
            }
            Expected = @{
                IsValid         = $false
                WhatChanges     = 'The input is removed.'
                RequiredUpgrade = $null
                Issues          = @(
                    @{ Code = 'required-upgrade-placeholder'; Message = "Replace the placeholder text in the 'Required upgrade' section." }
                )
            }
        }
        @{
            Id       = 'body-15'
            Title    = 'Filled fields on an unticked checkbox do not declare a breaking change'
            Design   = 'Breaking changes: the checkbox declares the change'
            Input    = @{
                Body = @'
- [ ] Breaking changes

### What changes

Nothing breaks.

### Required upgrade

None.
'@
            }
            Expected = @{
                IsValid        = $true
                BreakingChange = $false
                WhatChanges    = 'Nothing breaks.'
            }
        }
        @{
            Id       = 'body-16'
            Title    = 'A field heading inside a code fence does not count'
            Design   = 'Breaking changes: structure only'
            Input    = @{
                Body = @'
- [x] Breaking changes

```markdown
### What changes
```

### Required upgrade

Use the new input.
'@
            }
            Expected = @{
                IsValid = $false
                Issues  = @(
                    @{ Code = 'what-changes-missing' }
                )
            }
        }
    )
}
