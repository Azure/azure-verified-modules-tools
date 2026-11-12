@{
    Area      = 'release-metadata'
    Function  = 'Test-AvmReleaseMetadata'
    Scenarios = @(
        @{
            Id       = 'release-metadata-01'
            Title    = 'A human PR with one version label and the unticked template passes'
            Design   = 'The release-metadata check: human-authored PRs need exactly one version label'
            Input    = @{
                Author         = 'alice'
                Title          = 'feat: add zone support'
                Body           = @'
## Description

Add zone support.

- [ ] Breaking changes.

### What changes

Describe what breaks for consumers.

### Required upgrade

Describe what consumers must change.
'@
                Labels         = @('minor')
                ChangedFiles   = @(
                    @{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
                CurrentVersion = '0.4.1'
            }
            Expected = @{
                Tool            = 'release-metadata/1'
                Status          = 'pass'
                Kind            = 'Human'
                TriggersRelease = $true
                VersionLabel    = 'minor'
                VersionLabels   = @('minor')
                BreakingChange  = $false
                Issues          = @()
                Warnings        = @()
                IgnoredLabels   = @()
                'Notes~'        = 'starts a pending release'
            }
        }
        @{
            Id       = 'release-metadata-02'
            Title    = 'A human PR with no version label fails'
            Design   = 'The release-metadata check: human-authored PRs need exactly one version label'
            Input    = @{
                Author       = 'alice'
                Title        = 'fix: correct the default SKU'
                Body         = '- [ ] Breaking changes.'
                Labels       = @('enhancement')
                ChangedFiles = @(
                    @{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Status          = 'fail'
                Kind            = 'Human'
                TriggersRelease = $true
                VersionLabel    = $null
                VersionLabels   = @()
                Issues          = @(
                    @{ Code = 'missing-label'; 'Message~' = 'Every human-authored pull request needs exactly one'; 'Remedy~' = "Add one of 'patch', 'minor', 'major'" }
                )
            }
        }
        @{
            Id       = 'release-metadata-03'
            Title    = 'A human PR with two version labels fails and names both'
            Design   = 'The release-metadata check: human-authored PRs need exactly one version label'
            Input    = @{
                Author = 'alice'
                Title  = 'feat: add zone support'
                Body   = '- [ ] Breaking changes.'
                Labels = @('patch', 'minor')
            }
            Expected = @{
                Status        = 'fail'
                VersionLabel  = $null
                VersionLabels = @('patch', 'minor')
                Issues        = @(
                    @{ Code = 'conflicting-labels'; 'Message~' = 'patch, minor'; 'Remedy~' = 'exactly one' }
                )
            }
        }
        @{
            Id         = 'release-metadata-04'
            Title      = 'A human PR with only a documentation change still needs a version label'
            Design     = 'Which PRs trigger a release: every human-authored PR triggers a release'
            Assumption = 'The check follows the engine: authorship, not the changed files, decides whether a human PR needs a label.'
            Input      = @{
                Author       = 'alice'
                Title        = 'docs: clarify the example'
                Body         = '- [ ] Breaking changes.'
                ChangedFiles = @(
                    @{ Path = 'README.md'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected   = @{
                Status            = 'fail'
                ModuleCodeChanged = $false
                Issues            = @(
                    @{ Code = 'missing-label' }
                )
            }
        }
        @{
            Id       = 'release-metadata-05'
            Title    = 'A breaking change without the Required upgrade section fails'
            Design   = 'Breaking changes: What changes and Required upgrade must exist and must not be placeholders'
            Input    = @{
                Author         = 'alice'
                Title          = 'feat!: replace the subnet input'
                Body           = @'
- [x] Breaking changes.

### What changes

The `subnet_id` input is removed.
'@
                Labels         = @('major')
                CurrentVersion = '1.2.0'
            }
            Expected = @{
                Status         = 'fail'
                BreakingChange = $true
                Issues         = @(
                    @{ Code = 'required-upgrade-missing'; 'Remedy~' = "Add a '### Required upgrade' heading" }
                )
            }
        }
        @{
            Id       = 'release-metadata-06'
            Title    = 'A breaking change that keeps the What changes placeholder fails'
            Design   = 'Breaking changes: What changes and Required upgrade must exist and must not be placeholders'
            Input    = @{
                Author         = 'alice'
                Title          = 'feat!: replace the subnet input'
                Body           = @'
- [x] Breaking changes.

### What changes

Describe what breaks for consumers.

### Required upgrade

Replace `subnet_id` with `subnet_resource_id`.
'@
                Labels         = @('minor')
                CurrentVersion = '0.4.1'
            }
            Expected = @{
                Status = 'fail'
                Issues = @(
                    @{ Code = 'what-changes-placeholder'; 'Remedy~' = "Under '### What changes', write what breaks" }
                )
            }
        }
        @{
            Id       = 'release-metadata-07'
            Title    = 'A complete breaking-change declaration with a major label after 1.0.0 passes'
            Design   = 'Breaking changes'
            Input    = @{
                Author         = 'alice'
                Title          = 'feat!: replace the subnet input'
                Body           = @'
<!-- Tick the box when consumers must change their code. -->
- [x] Breaking changes.

### What changes

The `subnet_id` input is removed, so configurations that set it fail to plan.

### Required upgrade

Replace `subnet_id` with `subnet_resource_id`.
'@
                Labels         = @('major')
                CurrentVersion = 'v1.2.0'
            }
            Expected = @{
                Status         = 'pass'
                BreakingChange = $true
                VersionLabel   = 'major'
                Issues         = @()
            }
        }
        @{
            Id         = 'release-metadata-08'
            Title      = 'A human PR whose description has no breaking-changes checkbox fails'
            Design     = 'Breaking changes: the PR template has a checkbox'
            Assumption = 'RequireBreakingCheckbox is on, so a human who deletes the template cannot skip the breaking-change fields. Bot PRs never need the line.'
            Input      = @{
                Author = 'alice'
                Title  = 'fix: correct the default SKU'
                Body   = 'Fixes the default SKU.'
                Labels = @('patch')
            }
            Expected   = @{
                Status = 'fail'
                Issues = @(
                    @{ Code = 'breaking-checkbox-missing'; 'Remedy~' = "Restore the '- \[ \] Breaking changes\.' line" }
                )
            }
        }
        @{
            Id         = 'release-metadata-09'
            Title      = 'A human PR with an empty description fails on the missing checkbox'
            Design     = 'Breaking changes: the PR template has a checkbox'
            Assumption = 'A null description is treated as an empty one.'
            Input      = @{
                Author = 'alice'
                Title  = 'fix: correct the default SKU'
                Body   = $null
                Labels = @('patch')
            }
            Expected   = @{
                Status = 'fail'
                Issues = @(
                    @{ Code = 'breaking-checkbox-missing' }
                )
            }
        }
        @{
            Id       = 'release-metadata-10'
            Title    = 'Two breaking-changes checkboxes fail as ambiguous'
            Design   = 'Breaking changes'
            Input    = @{
                Author = 'alice'
                Title  = 'fix: correct the default SKU'
                Body   = "- [ ] Breaking changes.`n- [ ] Breaking changes."
                Labels = @('patch')
            }
            Expected = @{
                Status = 'fail'
                Issues = @(
                    @{ Code = 'breaking-checkbox-ambiguous' }
                )
            }
        }
        @{
            Id         = 'release-metadata-11'
            Title      = 'Version labels match case-insensitively, and other labels are ignored'
            Design     = 'Version labels'
            Assumption = 'Duplicate labels that differ only in case count once.'
            Input      = @{
                Author = 'alice'
                Title  = 'feat: add zone support'
                Body   = '- [ ] Breaking changes.'
                Labels = @('Minor', 'enhancement', ' MINOR ', @{ Name = 'documentation'; AddedBy = 'alice' })
            }
            Expected   = @{
                Status        = 'pass'
                VersionLabel  = 'minor'
                VersionLabels = @('minor')
            }
        }
        @{
            Id       = 'release-metadata-12'
            Title    = 'A major label before 1.0.0 fails'
            Design   = 'Version labels: before 1.0.0, reject major labels'
            Input    = @{
                Author         = 'alice'
                Title          = 'feat!: replace the subnet input'
                Body           = "- [x] Breaking changes.`n`n### What changes`n`nThe input is removed.`n`n### Required upgrade`n`nUse the new input."
                Labels         = @('major')
                CurrentVersion = '0.4.1'
            }
            Expected = @{
                Status = 'fail'
                Issues = @(
                    @{ Code = 'major-before-1.0'; 'Message~' = '0\.4\.1'; 'Remedy~' = "with 'minor'" }
                )
            }
        }
        @{
            Id         = 'release-metadata-13'
            Title      = 'A major label passes when no version is published yet'
            Design     = 'Version labels'
            Assumption = 'Without a published version the check cannot tell the major version, so it does not apply the before-1.0.0 rule. The engine decides at publication.'
            Input      = @{
                Author = 'alice'
                Title  = 'feat: first release'
                Body   = '- [ ] Breaking changes.'
                Labels = @('major')
            }
            Expected   = @{
                Status       = 'pass'
                VersionLabel = 'major'
            }
        }
        @{
            Id       = 'release-metadata-14'
            Title    = 'A current version that is not MAJOR.MINOR.PATCH is rejected'
            Design   = 'Version labels'
            Input    = @{
                Author         = 'alice'
                Labels         = @('patch')
                CurrentVersion = '1.2'
            }
            Throws   = "CurrentVersion '1\.2' is not a MAJOR\.MINOR\.PATCH version\."
        }
        @{
            Id       = 'release-metadata-15'
            Title    = 'A Dependabot PR that changes module code beyond formatting without a label fails'
            Design   = 'Bot PRs that change module code: a routine bot PR needs a label when it changes module code beyond formatting'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump azurerm to 4.1.0'
                Body         = 'Bumps azurerm.'
                ChangedFiles = @(
                    @{ Path = 'terraform.tf'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = 'examples/default/terraform.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Status            = 'fail'
                Kind              = 'RoutineBot'
                TriggersRelease   = $true
                ModuleCodeChanged = $true
                FormattingOnly    = $false
                ModuleCodeFiles   = @('terraform.tf')
                Issues            = @(
                    @{ Code = 'missing-label'; 'Message~' = "beyond formatting: 'terraform\.tf'\.$"; 'Remedy~' = 'by hand\. Automation must never add it\.' }
                )
            }
        }
        @{
            Id       = 'release-metadata-16'
            Title    = 'A Dependabot PR whose module code changes are formatting only passes without a label'
            Design   = 'Bot PRs that change module code: formatting-only changes do not need a label'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump azurerm'
                ChangedFiles = @(
                    @{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $true }
                    @{ Path = 'modules/child/main.tf'; Status = 'changed'; FormatEquivalent = $true }
                )
            }
            Expected = @{
                Status            = 'pass'
                Kind              = 'RoutineBot'
                TriggersRelease   = $false
                ModuleCodeChanged = $true
                FormattingOnly    = $true
                Issues            = @()
                'Notes~'          = '(?s)needs no version label and does not trigger a release.*formatting only'
            }
        }
        @{
            Id       = 'release-metadata-17'
            Title    = 'A Dependabot PR that changes only examples and workflows passes without a label'
            Design   = 'Bot PRs that change module code: module code is root *.tf and modules/'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump actions/checkout'
                ChangedFiles = @(
                    @{ Path = 'examples/default/main.tf'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = '.github/workflows/pr-check.yml'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Status            = 'pass'
                TriggersRelease   = $false
                ModuleCodeChanged = $false
                Issues            = @()
            }
        }
        @{
            Id       = 'release-metadata-18'
            Title    = 'A Dependabot PR that renames a module file needs a label even if the content is unchanged'
            Design   = 'Bot PRs that change module code: added, removed, or renamed files are never formatting only'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore: move locals'
                ChangedFiles = @(
                    @{ Path = 'locals.tf'; PreviousPath = 'main.locals.tf'; Status = 'renamed'; FormatEquivalent = $true }
                )
            }
            Expected = @{
                Status         = 'fail'
                FormattingOnly = $false
                Issues         = @(
                    @{ Code = 'missing-label' }
                )
            }
        }
        @{
            Id       = 'release-metadata-19'
            Title    = 'A bot missing-label message lists at most five module files'
            Design   = 'The release-metadata check: the job summary tells the author exactly how to fix a failure'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump azurerm'
                ChangedFiles = @(
                    @{ Path = 'a.tf'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = 'b.tf'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = 'c.tf'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = 'd.tf'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = 'e.tf'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = 'f.tf'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = 'g.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Status = 'fail'
                Issues = @(
                    @{ Code = 'missing-label'; 'Message~' = "'e\.tf', and 2 more\.$" }
                )
            }
        }
        @{
            Id         = 'release-metadata-20'
            Title      = 'A Dependabot PR with an unknown file list is treated as changing module code'
            Design     = 'Bot PRs that change module code'
            Assumption = 'When GitHub cannot list every changed file, the check fails safe and requires a label.'
            Input      = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump azurerm'
                ChangedFiles = $null
            }
            Expected   = @{
                Status            = 'fail'
                ModuleCodeChanged = $true
                Issues            = @(
                    @{ Code = 'missing-label'; 'Message~' = 'could not list the changed files' }
                )
                'Notes~'          = 'changed files are unknown'
            }
        }
        @{
            Id         = 'release-metadata-21'
            Title      = 'A Dependabot PR opted in by a person passes without the breaking-changes checkbox'
            Design     = 'PR types: a routine bot PR with an opt-in label follows the human rules'
            Assumption = 'Bot descriptions never contain the template, so a missing checkbox on an opt-in means no breaking change.'
            Input      = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump azurerm'
                Body         = 'Bumps azurerm from 4.0.0 to 4.1.0.'
                Labels       = @(@{ Name = 'patch'; AddedBy = 'alice' })
                ChangedFiles = @(
                    @{ Path = 'terraform.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected   = @{
                Status          = 'pass'
                Kind            = 'RoutineBot'
                TriggersRelease = $true
                VersionLabel    = 'patch'
                IgnoredLabels   = @()
                'Notes~'        = 'opt-in\. The release engine accepts it only from a module owner'
            }
        }
        @{
            Id       = 'release-metadata-22'
            Title    = 'An opted-in Dependabot PR that ticks the box must fill in the breaking-change fields'
            Design   = 'PR types: a routine bot PR with an opt-in label follows the human rules'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump azurerm to 5.0.0'
                Body         = "- [x] Breaking changes.`n`n### What changes`n`nDescribe what breaks for consumers.`n`n### Required upgrade`n`nDescribe what consumers must change."
                Labels       = @(@{ Name = 'minor'; AddedBy = 'alice' })
                ChangedFiles = @(
                    @{ Path = 'terraform.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Status = 'fail'
                Issues = @(
                    @{ Code = 'what-changes-placeholder' }
                    @{ Code = 'required-upgrade-placeholder' }
                )
            }
        }
        @{
            Id       = 'release-metadata-23'
            Title    = 'A version label added by a bot does not opt in a bot PR'
            Design   = 'The release-metadata check: never add a version label automatically'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump azurerm'
                Labels       = @(@{ Name = 'patch'; AddedBy = 'github-actions[bot]' })
                ChangedFiles = @(
                    @{ Path = 'terraform.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Status        = 'fail'
                VersionLabels = @()
                Issues        = @(
                    @{ Code = 'missing-label' }
                )
                IgnoredLabels = @(
                    @{ Name = 'patch'; AddedBy = 'github-actions[bot]'; Reason = 'bot'; 'Message~' = 'added by automation' }
                )
                'Warnings#'   = 1
            }
        }
        @{
            Id         = 'release-metadata-24'
            Title      = 'A version label with no known actor does not opt in a bot PR'
            Design     = 'The release-metadata check: never add a version label automatically'
            Assumption = 'When the issue events do not show who added a label, the label is not an opt-in. A formatting-only bot PR still passes.'
            Input      = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump azurerm'
                Labels       = @('minor')
                ChangedFiles = @(
                    @{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $true }
                )
            }
            Expected   = @{
                Status          = 'pass'
                TriggersRelease = $false
                VersionLabel    = $null
                IgnoredLabels   = @(
                    @{ Name = 'minor'; AddedBy = $null; Reason = 'missing-actor' }
                )
                'Warnings~'     = "Ignored the 'minor' label"
            }
        }
        @{
            Id       = 'release-metadata-25'
            Title    = 'A repo-sync PR passes without a label and never triggers a release'
            Design   = 'Repo-sync pull requests: never need a label and never trigger a release'
            Input    = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: run avm pre-commit'
                Body         = 'Automated repository sync.'
                ChangedFiles = @(
                    @{ Path = '.github/workflows/pr-check.yml'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = 'main.telemetry.tf'; Status = 'modified'; FormatEquivalent = $true }
                )
            }
            Expected = @{
                Status          = 'pass'
                Kind            = 'Automation'
                TriggersRelease = $false
                Issues          = @()
                Notes           = @('This is a repo-sync pull request. It needs no version label and never triggers a release. Its changes ship with the next release.')
            }
        }
        @{
            Id       = 'release-metadata-26'
            Title    = 'A repo-sync PR that changes module code beyond formatting passes with a review note'
            Design   = 'Repo-sync pull requests: never need a label, and module code beyond formatting is flagged'
            Input    = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: run avm pre-commit (mapotf)'
                ChangedFiles = @(
                    @{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Status          = 'pass'
                Kind            = 'Automation'
                TriggersRelease = $false
                'Notes~'        = 'flag it for review'
            }
        }
        @{
            Id         = 'release-metadata-27'
            Title      = 'A repo-sync PR opted in by a person follows the human label rules'
            Design     = 'PR types: a bot PR with an opt-in label follows the human rules'
            Assumption = 'An opt-in on a repo-sync PR is handled like an opt-in on any bot PR.'
            Input      = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: run avm pre-commit'
                Labels       = @(@{ Name = 'patch'; AddedBy = 'alice' }, @{ Name = 'minor'; AddedBy = 'bob' })
                ChangedFiles = @(
                    @{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected   = @{
                Status          = 'fail'
                Kind            = 'Automation'
                TriggersRelease = $true
                Issues          = @(
                    @{ Code = 'conflicting-labels' }
                )
            }
        }
        @{
            Id       = 'release-metadata-28'
            Title    = 'The repo-sync author with another title is a routine bot'
            Design   = 'PR types: repo-sync PRs are identified by author and title prefix'
            Input    = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: update managed files'
                ChangedFiles = @(
                    @{ Path = 'variables.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Status = 'fail'
                Kind   = 'RoutineBot'
                Issues = @(
                    @{ Code = 'missing-label' }
                )
            }
        }
        @{
            Id         = 'release-metadata-29'
            Title      = 'An unknown bot gets the human rules'
            Design     = 'PR types: unknown identities get the stricter human rules'
            Input      = @{
                Author       = 'renovate[bot]'
                Title        = 'chore(deps): update azurerm'
                Body         = 'Updates azurerm.'
                Labels       = @(@{ Name = 'patch'; AddedBy = 'renovate[bot]' })
                ChangedFiles = @(
                    @{ Path = 'examples/default/main.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected   = @{
                Status        = 'fail'
                Kind          = 'Human'
                VersionLabel  = 'patch'
                IgnoredLabels = @()
                Issues        = @(
                    @{ Code = 'breaking-checkbox-missing' }
                )
            }
        }
    )
}
