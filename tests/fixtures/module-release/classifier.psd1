@{
    Area      = 'classifier'
    Function  = 'Get-AvmReleasePullRequestClass'
    Scenarios = @(
        @{
            Id       = 'classifier-01'
            Title    = 'A human PR that changes root module code needs a version label'
            Design   = 'Which PRs trigger a release: human PRs'
            Input    = @{
                Author       = 'alice'
                Title        = 'feat: add zone support'
                ChangedFiles = @(
                    @{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = 'variables.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Kind                 = 'Human'
                ModuleCodeChanged    = $true
                FormattingOnly       = $false
                ModuleCodeFiles      = @('main.tf', 'variables.tf')
                RequiresVersionLabel = $true
                NeedsAttention       = $false
            }
        }
        @{
            Id         = 'classifier-02'
            Title      = 'A human PR that changes only documentation still needs a version label'
            Design     = 'Which PRs trigger a release: every human-authored PR triggers a release'
            Assumption = 'Every human PR triggers a release and needs a version label, even without module code changes. The design ties triggering to authorship, not to the files.'
            Input      = @{
                Author       = 'alice'
                Title        = 'docs: clarify the example'
                ChangedFiles = @(
                    @{ Path = 'README.md'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected   = @{
                Kind                 = 'Human'
                ModuleCodeChanged    = $false
                FormattingOnly       = $false
                ModuleCodeFiles      = @()
                RequiresVersionLabel = $true
            }
        }
        @{
            Id       = 'classifier-03'
            Title    = 'A Dependabot PR that changes only examples is routine'
            Design   = 'Which PRs trigger a release: routine bot PRs ride along'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump azurerm in examples'
                ChangedFiles = @(
                    @{ Path = 'examples/default/main.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Kind                 = 'RoutineBot'
                ModuleCodeChanged    = $false
                RequiresVersionLabel = $false
                NeedsAttention       = $false
            }
        }
        @{
            Id         = 'classifier-04'
            Title      = 'A Dependabot PR that changes root module code needs a version label'
            Design     = 'The release-metadata check: a bot PR that changes module code beyond formatting needs a label'
            Assumption = 'A routine bot PR that changes module code beyond formatting needs a version label. When it merges without one, it triggers a release that the missing label blocks.'
            Input      = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump azurerm'
                ChangedFiles = @(
                    @{ Path = 'terraform.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected   = @{
                Kind                 = 'RoutineBot'
                ModuleCodeChanged    = $true
                FormattingOnly       = $false
                RequiresVersionLabel = $true
                NeedsAttention       = $false
            }
        }
        @{
            Id       = 'classifier-05'
            Title    = 'A Dependabot PR that changes only workflows is routine'
            Design   = 'Which PRs trigger a release: routine bot PRs ride along'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump actions/checkout'
                ChangedFiles = @(
                    @{ Path = '.github/workflows/pr-check.yml'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Kind                 = 'RoutineBot'
                ModuleCodeChanged    = $false
                RequiresVersionLabel = $false
            }
        }
        @{
            Id       = 'classifier-06'
            Title    = 'A repo-sync PR with only formatting changes to module code needs no attention'
            Design   = 'Formatting-only changes: identical after terraform fmt on both sides'
            Input    = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: run avm pre-commit'
                ChangedFiles = @(
                    @{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $true }
                    @{ Path = 'README.md'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Kind                 = 'Automation'
                ModuleCodeChanged    = $true
                FormattingOnly       = $true
                ModuleCodeFiles      = @('main.tf')
                RequiresVersionLabel = $false
                NeedsAttention       = $false
            }
        }
        @{
            Id       = 'classifier-07'
            Title    = 'A repo-sync PR that changes module code beyond formatting needs attention but no label'
            Design   = 'Repo-sync pull requests: never trigger a release, and module code beyond formatting is flagged'
            Input    = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: run avm pre-commit'
                ChangedFiles = @(
                    @{ Path = 'main.telemetry.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                Kind                 = 'Automation'
                ModuleCodeChanged    = $true
                FormattingOnly       = $false
                RequiresVersionLabel = $false
                NeedsAttention       = $true
            }
        }
        @{
            Id       = 'classifier-08'
            Title    = 'An added module file is never formatting-only'
            Design   = 'Formatting-only changes: no file is added, removed, or renamed'
            Input    = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: run avm pre-commit'
                ChangedFiles = @(
                    @{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $true }
                    @{ Path = 'main.telemetry.tf'; Status = 'added'; FormatEquivalent = $true }
                )
            }
            Expected = @{
                FormattingOnly = $false
                NeedsAttention = $true
            }
        }
        @{
            Id       = 'classifier-09'
            Title    = 'A renamed submodule file is never formatting-only'
            Design   = 'Formatting-only changes: no file is added, removed, or renamed'
            Input    = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: run avm pre-commit'
                ChangedFiles = @(
                    @{ Path = 'modules/x/main.tf'; PreviousPath = 'modules/y/main.tf'; Status = 'renamed'; FormatEquivalent = $true }
                )
            }
            Expected = @{
                ModuleCodeChanged = $true
                FormattingOnly    = $false
                ModuleCodeFiles   = @('modules/x/main.tf')
                NeedsAttention    = $true
            }
        }
        @{
            Id       = 'classifier-10'
            Title    = 'A removed module file is never formatting-only'
            Design   = 'Formatting-only changes: no file is added, removed, or renamed'
            Input    = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: run avm pre-commit'
                ChangedFiles = @(
                    @{ Path = 'locals.tf'; Status = 'removed'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                FormattingOnly = $false
                NeedsAttention = $true
            }
        }
        @{
            Id       = 'classifier-11'
            Title    = 'A file moved out of module code still counts through its previous path'
            Design   = 'Which PRs trigger a release: module code'
            Input    = @{
                Author       = 'alice'
                Title        = 'refactor: move a helper'
                ChangedFiles = @(
                    @{ Path = 'examples/default/helper.tf'; PreviousPath = 'helper.tf'; Status = 'renamed'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                ModuleCodeChanged = $true
                ModuleCodeFiles   = @('examples/default/helper.tf')
            }
        }
        @{
            Id       = 'classifier-12'
            Title    = 'A root .tf.json file is module code'
            Design   = 'Which PRs trigger a release: module code'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump'
                ChangedFiles = @(
                    @{ Path = 'override.tf.json'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                ModuleCodeChanged    = $true
                RequiresVersionLabel = $true
            }
        }
        @{
            Id       = 'classifier-13'
            Title    = 'Terraform files under examples and tests are not module code'
            Design   = 'Which PRs trigger a release: module code is root *.tf and modules/**'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump'
                ChangedFiles = @(
                    @{ Path = 'examples/default/main.tf'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = 'tests/unit/main.tftest.hcl'; Status = 'modified'; FormatEquivalent = $false }
                    @{ Path = 'tests/integration/main.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                ModuleCodeChanged = $false
                ModuleCodeFiles   = @()
            }
        }
        @{
            Id         = 'classifier-14'
            Title      = 'An unknown file list counts as a module code change'
            Design     = 'Which PRs trigger a release'
            Assumption = 'When the changed files are unknown, the classifier fails safe and treats the PR as changing module code beyond formatting.'
            Input      = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: run avm pre-commit'
                ChangedFiles = $null
            }
            Expected   = @{
                ModuleCodeChanged = $true
                FormattingOnly    = $false
                ModuleCodeFiles   = @()
                NeedsAttention    = $true
            }
        }
        @{
            Id       = 'classifier-15'
            Title    = 'An empty file list changes no module code and is not formatting-only'
            Design   = 'Which PRs trigger a release'
            Input    = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: run avm pre-commit'
                ChangedFiles = @()
            }
            Expected = @{
                ModuleCodeChanged = $false
                FormattingOnly    = $false
                NeedsAttention    = $false
            }
        }
        @{
            Id         = 'classifier-16'
            Title      = 'An unknown bot gets the human rules'
            Design     = 'Which PRs trigger a release'
            Assumption = 'Only listed routine bots get the routine rules. Unknown bots, such as renovate[bot], are treated as humans.'
            Input      = @{
                Author       = 'renovate[bot]'
                Title        = 'chore(deps): bump'
                ChangedFiles = @(
                    @{ Path = 'examples/default/main.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected   = @{
                Kind                 = 'Human'
                RequiresVersionLabel = $true
            }
        }
        @{
            Id         = 'classifier-17'
            Title      = 'Other PRs from the AVM bot are routine, not repo-sync'
            Design     = 'Repo-sync pull requests: the AVM bot is the author and the title starts with chore: run avm pre-commit'
            Assumption = 'Repo-sync identity needs both the author and the title prefix. Other azure-verified-modules[bot] PRs follow the routine bot rules.'
            Input      = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = 'chore: update CODEOWNERS'
                ChangedFiles = @(
                    @{ Path = '.github/CODEOWNERS'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected   = @{
                Kind                 = 'RoutineBot'
                RequiresVersionLabel = $false
            }
        }
        @{
            Id       = 'classifier-18'
            Title    = 'The repo-sync title prefix is case-insensitive'
            Design   = 'Repo-sync pull requests'
            Input    = @{
                Author       = 'azure-verified-modules[bot]'
                Title        = '  Chore: Run AVM pre-commit (sync 42)'
                ChangedFiles = @()
            }
            Expected = @{
                Kind = 'Automation'
            }
        }
        @{
            Id       = 'classifier-19'
            Title    = 'A human-looking title from a human author is never repo-sync'
            Design   = 'Repo-sync pull requests'
            Input    = @{
                Author       = 'alice'
                Title        = 'chore: run avm pre-commit'
                ChangedFiles = @(
                    @{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $true }
                )
            }
            Expected = @{
                Kind                 = 'Human'
                FormattingOnly       = $true
                RequiresVersionLabel = $true
                NeedsAttention       = $false
            }
        }
        @{
            Id       = 'classifier-20'
            Title    = 'Backslash paths are normalised'
            Design   = 'Which PRs trigger a release: module code'
            Input    = @{
                Author       = 'alice'
                Title        = 'fix: submodule'
                ChangedFiles = @(
                    @{ Path = 'modules\x\main.tf'; Status = 'modified'; FormatEquivalent = $false }
                )
            }
            Expected = @{
                ModuleCodeChanged = $true
                ModuleCodeFiles   = @('modules/x/main.tf')
            }
        }
        @{
            Id       = 'classifier-21'
            Title    = 'A routine bot formatting-only module change needs no label'
            Design   = 'Formatting-only changes: not module code changes beyond formatting'
            Input    = @{
                Author       = 'dependabot[bot]'
                Title        = 'chore(deps): bump'
                ChangedFiles = @(
                    @{ Path = 'modules/x/variables.tf'; Status = 'changed'; FormatEquivalent = $true }
                )
            }
            Expected = @{
                Kind                 = 'RoutineBot'
                ModuleCodeChanged    = $true
                FormattingOnly       = $true
                RequiresVersionLabel = $false
            }
        }
    )
}
