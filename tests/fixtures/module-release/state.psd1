@{
    Area       = 'state'
    BaseState  = @{
        schemaVersion = 1
        repository    = 'Azure/terraform-azurerm-avm-res-example'
        releaseIssue  = @{ number = 200 }
        commentCursor = @{ createdAt = '2026-09-07T12:00:00Z'; id = 9001 }
        labelCursor   = @{ at = '2026-09-07T11:00:00Z'; id = 7001 }
        hold          = $null
        pending       = @{
            pullRequests   = @(
                @{
                    number            = 142
                    title             = 'feat!: replace `subnet_id` with `subnet_resource_id`'
                    author            = 'alice'
                    kind              = 'Human'
                    mergedAt          = '2026-09-07T09:00:00Z'
                    mergeCommit       = '0000000000000000000000000000000000000142'
                    triggersRelease   = $true
                    triggeredAt       = '2026-09-07T09:00:00Z'
                    triggeredBy       = 'merge'
                    optIn             = $null
                    versionLabels     = @('minor')
                    labelChanges      = @()
                    breaking          = @{
                        declared        = $true
                        whatChanges     = 'The `subnet_id` input is removed, so configurations that set it fail to plan.'
                        requiredUpgrade = 'Replace `subnet_id` with `subnet_resource_id`.'
                        issues          = @()
                    }
                    moduleCodeChanged = $true
                    formattingOnly    = $false
                    flags             = @()
                }
                @{
                    number            = 144
                    title             = 'chore: run avm pre-commit'
                    author            = 'azure-verified-modules[bot]'
                    kind              = 'Automation'
                    mergedAt          = '2026-09-07T10:00:00Z'
                    mergeCommit       = '0000000000000000000000000000000000000144'
                    triggersRelease   = $false
                    triggeredAt       = $null
                    triggeredBy       = $null
                    optIn             = $null
                    versionLabels     = @()
                    labelChanges      = @()
                    breaking          = @{
                        declared        = $false
                        whatChanges     = $null
                        requiredUpgrade = $null
                        issues          = @()
                    }
                    moduleCodeChanged = $true
                    formattingOnly    = $true
                    flags             = @()
                }
                @{
                    number            = 146
                    title             = 'chore(deps): bump azurerm'
                    author            = 'dependabot[bot]'
                    kind              = 'RoutineBot'
                    mergedAt          = '2026-09-07T10:30:00Z'
                    mergeCommit       = '0000000000000000000000000000000000000146'
                    triggersRelease   = $true
                    triggeredAt       = '2026-09-07T11:00:00Z'
                    triggeredBy       = 'opt-in'
                    optIn             = @{ by = 'alice'; at = '2026-09-07T11:00:00Z' }
                    versionLabels     = @('patch')
                    labelChanges      = @(
                        @{ label = 'patch'; action = 'labeled'; actor = 'alice'; at = '2026-09-07T11:00:00Z' }
                    )
                    breaking          = @{
                        declared        = $false
                        whatChanges     = $null
                        requiredUpgrade = $null
                        issues          = @()
                    }
                    moduleCodeChanged = $true
                    formattingOnly    = $false
                    flags             = @()
                }
            )
            releaseRequest = $null
            notes          = @{
                commentary       = @{
                    text  = 'This release prepares the module for shared network inputs.'
                    setBy = 'alice'
                    setAt = '2026-09-07T12:00:00Z'
                }
                breakingOverride = $null
            }
        }
        publication   = @{
            version         = '0.8.2'
            previousVersion = '0.8.1'
            commit          = '0000000000000000000000000000000000000140'
            cutoffAt        = '2026-09-07T08:00:00Z'
            trigger         = 'cap'
            stage           = 'cutoff'
            pullRequests    = @(
                @{ number = 140; versionLabel = 'patch' }
            )
        }
    }
    BaseRecord = @{
        schemaVersion   = 1
        repository      = 'Azure/terraform-azurerm-avm-res-example'
        version         = '0.9.0'
        previousVersion = '0.8.2'
        increment       = 'minor'
        commit          = '0000000000000000000000000000000000000900'
        cutoffAt        = '2026-09-08T09:00:00Z'
        trigger         = 'timer'
        requestedBy     = $null
        notes           = @'
## What's changed

- feat!: replace `subnet_id` with `subnet_resource_id` (#142)

'@
        pullRequests    = @(
            @{
                number          = 142
                title           = 'feat!: replace `subnet_id` with `subnet_resource_id`'
                author          = 'alice'
                kind            = 'Human'
                mergedAt        = '2026-09-07T09:00:00Z'
                mergeCommit     = '0000000000000000000000000000000000000142'
                triggersRelease = $true
                versionLabel    = 'minor'
                breaking        = $true
            }
            @{
                number          = 144
                title           = 'chore: run avm pre-commit'
                author          = 'azure-verified-modules[bot]'
                kind            = 'Automation'
                mergedAt        = '2026-09-07T10:00:00Z'
                mergeCommit     = '0000000000000000000000000000000000000144'
                triggersRelease = $false
                versionLabel    = $null
                breaking        = $false
            }
        )
    }
    Scenarios  = @(
        @{
            Id       = 'state-01'
            Title    = 'The base state is valid'
            Design   = 'Release state: state.json holds the pending release, the comment cursor, holds, and progress'
            Kind     = 'State'
            Expected = @{ IsValid = $true; Issues = @() }
        }
        @{
            Id       = 'state-02'
            Title    = 'An unsupported schema version is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'schemaVersion'; Value = 2 }
            )
            Expected = @{
                IsValid = $false
                Issues  = @('$.schemaVersion: version ''2'' is not supported. Expected 1.')
            }
        }
        @{
            Id       = 'state-03'
            Title    = 'A missing schema version is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Remove = 'schemaVersion' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.schemaVersion: is missing.') }
        }
        @{
            Id       = 'state-04'
            Title    = 'A schema version that is not a number is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'schemaVersion'; Value = '1' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.schemaVersion: must be a positive integer.') }
        }
        @{
            Id       = 'state-05'
            Title    = 'An unknown property is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'extra'; Value = 'x' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.extra: is not a known property.') }
        }
        @{
            Id       = 'state-06'
            Title    = 'A property with different casing is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Remove = 'hold' }
                @{ Set = 'Hold'; Value = $null }
            )
            Expected = @{
                IsValid = $false
                Issues  = @(
                    '$.Hold: is not a known property.'
                    '$.hold: is missing.'
                )
            }
        }
        @{
            Id       = 'state-07'
            Title    = 'A missing pending section is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Remove = 'pending' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending: is missing.') }
        }
        @{
            Id       = 'state-08'
            Title    = 'A timestamp without UTC form is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].mergedAt'; Value = '2026-09-07T09:00:00+01:00' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0].mergedAt: must be a UTC timestamp such as 2026-09-07T09:00:00Z.') }
        }
        @{
            Id       = 'state-09'
            Title    = 'An impossible date is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'commentCursor.createdAt'; Value = '2026-02-30T09:00:00Z' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.commentCursor.createdAt: must be a UTC timestamp such as 2026-09-07T09:00:00Z.') }
        }
        @{
            Id       = 'state-10'
            Title    = 'An uppercase commit SHA is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].mergeCommit'; Value = '000000000000000000000000000000000000ABCD' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0].mergeCommit: must be a 40-character lowercase commit SHA.') }
        }
        @{
            Id       = 'state-11'
            Title    = 'An unknown version label is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].versionLabels[0]'; Value = 'huge' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0].versionLabels[0]: must be one of patch, minor, major.') }
        }
        @{
            Id       = 'state-12'
            Title    = 'A pull request kind with the wrong case is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].kind'; Value = 'human' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0].kind: must be one of Human, RoutineBot, Automation.') }
        }
        @{
            Id       = 'state-13'
            Title    = 'A zero pull request number is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].number'; Value = 0 }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0].number: must be a positive integer.') }
        }
        @{
            Id       = 'state-14'
            Title    = 'A string in a boolean field is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].triggersRelease'; Value = 'yes' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0].triggersRelease: must be true or false.') }
        }
        @{
            Id       = 'state-15'
            Title    = 'A string where an array belongs is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].versionLabels'; Value = 'minor' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0].versionLabels: must be an array.') }
        }
        @{
            Id       = 'state-16'
            Title    = 'An empty author is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].author'; Value = '' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0].author: must be a non-empty string.') }
        }
        @{
            Id       = 'state-17'
            Title    = 'A null required field is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].title'; Value = $null }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0].title: is required.') }
        }
        @{
            Id       = 'state-18'
            Title    = 'A scalar where an object belongs is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'releaseIssue'; Value = 200 }
            )
            Expected = @{ IsValid = $false; Issues = @('$.releaseIssue: must be an object.') }
        }
        @{
            Id       = 'state-19'
            Title    = 'A pull request listed twice is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[1].number'; Value = 142 }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[1].number: pull request #142 is listed more than once.') }
        }
        @{
            Id       = 'state-20'
            Title    = 'A release-triggering pull request without a trigger time is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].triggeredAt'; Value = $null }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0]: a release-triggering pull request needs triggeredAt and triggeredBy.') }
        }
        @{
            Id       = 'state-21'
            Title    = 'A repo-sync pull request that triggers at merge is damage'
            Design   = 'Repo-sync pull requests: never trigger a release unless a module owner opts one in'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[1].triggeredBy'; Value = 'merge' }
            )
            Expected = @{
                IsValid = $false
                Issues  = @(
                    '$.pending.pullRequests[1]: a pull request that does not trigger a release cannot have trigger details.'
                    '$.pending.pullRequests[1]: a repo-sync pull request can trigger a release only through an opt-in.'
                )
            }
        }
        @{
            Id       = 'state-22'
            Title    = 'An opt-in trigger without opt-in details is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[2].optIn'; Value = $null }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[2].optIn: an opt-in trigger needs the opt-in details.') }
        }
        @{
            Id       = 'state-23'
            Title    = 'A merge trigger with opt-in details is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].optIn'; Value = @{ by = 'alice'; at = '2026-09-07T09:00:00Z' } }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0].optIn: a merge trigger cannot have opt-in details.') }
        }
        @{
            Id       = 'state-24'
            Title    = 'A human pull request that does not trigger a release is damage'
            Design   = 'Which PRs trigger a release: every human-authored PR triggers a release'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[0].triggersRelease'; Value = $false }
                @{ Set = 'pending.pullRequests[0].triggeredAt'; Value = $null }
                @{ Set = 'pending.pullRequests[0].triggeredBy'; Value = $null }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[0]: a human-authored pull request must trigger a release at merge.') }
        }
        @{
            Id       = 'state-25'
            Title    = 'A formatting-only change without module code is damage'
            Design   = 'Formatting-only changes: apply only to module code'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[1].moduleCodeChanged'; Value = $false }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[1].formattingOnly: a formatting-only change must change module code.') }
        }
        @{
            Id       = 'state-26'
            Title    = 'A trigger before the merge is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'pending.pullRequests[2].triggeredAt'; Value = '2026-09-07T10:00:00Z' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pending.pullRequests[2].triggeredAt: a pull request cannot trigger a release before it merges.') }
        }
        @{
            Id       = 'state-27'
            Title    = 'A valid hold is accepted'
            Design   = 'Release state: state.json holds holds'
            Kind     = 'State'
            Patches  = @(
                @{
                    Set   = 'hold'
                    Value = @{
                        reason    = 'waiting for provider fix'
                        placedBy  = 'alice'
                        placedAt  = '2026-09-07T13:00:00Z'
                        since     = '2026-09-07T12:30:00Z'
                        commentId = 9002
                    }
                }
            )
            Expected = @{ IsValid = $true; Issues = @() }
        }
        @{
            Id       = 'state-28'
            Title    = 'A hold that starts after its latest update is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{
                    Set   = 'hold'
                    Value = @{
                        reason    = 'waiting for provider fix'
                        placedBy  = 'alice'
                        placedAt  = '2026-09-07T12:30:00Z'
                        since     = '2026-09-07T13:00:00Z'
                        commentId = 9002
                    }
                }
            )
            Expected = @{ IsValid = $false; Issues = @('$.hold.since: the hold cannot start after its latest update.') }
        }
        @{
            Id       = 'state-29'
            Title    = 'A pull request that is both pending and publishing is damage'
            Design   = 'Publication cutoff: the record fixes the included PRs'
            Kind     = 'State'
            Patches  = @(
                @{
                    Set   = 'publication.pullRequests'
                    Value = @(
                        @{ number = 140; versionLabel = 'patch' }
                        @{ number = 142; versionLabel = 'minor' }
                    )
                }
            )
            Expected = @{ IsValid = $false; Issues = @('$.publication.pullRequests[1].number: pull request #142 is both pending and publishing.') }
        }
        @{
            Id       = 'state-30'
            Title    = 'A pull request listed twice in a publication is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{
                    Set   = 'publication.pullRequests'
                    Value = @(
                        @{ number = 140; versionLabel = 'patch' }
                        @{ number = 140; versionLabel = 'patch' }
                    )
                }
            )
            Expected = @{ IsValid = $false; Issues = @('$.publication.pullRequests[1].number: pull request #140 is listed more than once.') }
        }
        @{
            Id       = 'state-31'
            Title    = 'A publication that does not change the version is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'publication.version'; Value = '0.8.1' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.publication.version: the new version must differ from the previous version.') }
        }
        @{
            Id       = 'state-32'
            Title    = 'An unknown publication stage is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Patches  = @(
                @{ Set = 'publication.stage'; Value = 'published' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.publication.stage: must be one of cutoff.') }
        }
        @{
            Id       = 'state-33'
            Title    = 'State from another repository is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Repository = 'Azure/terraform-azurerm-avm-res-other'
            Expected = @{ IsValid = $false; Issues = @('$.repository: state belongs to ''Azure/terraform-azurerm-avm-res-example'', not ''Azure/terraform-azurerm-avm-res-other''.') }
        }
        @{
            Id       = 'state-34'
            Title    = 'An empty document is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Json     = ''
            Expected = @{ IsValid = $false; Document = $null; Issues = @('$: The document is empty.') }
        }
        @{
            Id       = 'state-35'
            Title    = 'Malformed JSON is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Json     = '{"schemaVersion": 1,'
            Expected = @{ IsValid = $false; 'Issues~' = '^\$: Release state must be strict JSON: ' }
        }
        @{
            Id       = 'state-36'
            Title    = 'A JSON array is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Json     = '[]'
            Expected = @{ IsValid = $false; Issues = @('$: Release state must be a JSON object.') }
        }
        @{
            Id       = 'state-37'
            Title    = 'A duplicated property is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Json     = '{"schemaVersion": 1, "schemaVersion": 1}'
            Expected = @{ IsValid = $false; Issues = @('$: Duplicate JSON property ''schemaVersion''.') }
        }
        @{
            Id       = 'state-38'
            Title    = 'A property duplicated with different casing is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'State'
            Json     = '{"schemaVersion": 1, "SchemaVersion": 1}'
            Expected = @{ IsValid = $false; Issues = @('$: Duplicate JSON property ''SchemaVersion''.') }
        }
        @{
            Id       = 'record-01'
            Title    = 'The base release record is valid'
            Design   = 'Publication cutoff: the release record holds the commit, version, PRs, labels, and notes'
            Kind     = 'Record'
            Expected = @{ IsValid = $true; Issues = @() }
        }
        @{
            Id       = 'record-02'
            Title    = 'A record that does not change the version is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'Record'
            Patches  = @(
                @{ Set = 'version'; Value = '0.8.2' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.version: the new version must differ from the previous version.') }
        }
        @{
            Id       = 'record-03'
            Title    = 'A record without pull requests is damage'
            Design   = 'Publication cutoff: the record holds the included PRs'
            Kind     = 'Record'
            Patches  = @(
                @{ Set = 'pullRequests'; Value = @() }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pullRequests: a release must include at least one pull request.') }
        }
        @{
            Id       = 'record-04'
            Title    = 'A release-triggering pull request without its accepted label is damage'
            Design   = 'Publication cutoff: the record holds the accepted version labels'
            Kind     = 'Record'
            Patches  = @(
                @{ Set = 'pullRequests[0].versionLabel'; Value = $null }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pullRequests[0].versionLabel: a release-triggering pull request needs its accepted version label.') }
        }
        @{
            Id       = 'record-05'
            Title    = 'A pull request listed twice in a record is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'Record'
            Patches  = @(
                @{ Set = 'pullRequests[1].number'; Value = 142 }
            )
            Expected = @{ IsValid = $false; Issues = @('$.pullRequests[1].number: pull request #142 is listed more than once.') }
        }
        @{
            Id       = 'record-06'
            Title    = 'A version with a v prefix is damage'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'Record'
            Patches  = @(
                @{ Set = 'version'; Value = 'v0.9.0' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.version: must be a MAJOR.MINOR.PATCH version.') }
        }
        @{
            Id       = 'record-07'
            Title    = 'Empty notes are damage'
            Design   = 'Publication cutoff: the record holds the complete release notes'
            Kind     = 'Record'
            Patches  = @(
                @{ Set = 'notes'; Value = ' ' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.notes: must be a non-empty string.') }
        }
        @{
            Id       = 'record-08'
            Title    = 'A missing commit is damage'
            Design   = 'Publication cutoff: the record holds the exact commit'
            Kind     = 'Record'
            Patches  = @(
                @{ Remove = 'commit' }
            )
            Expected = @{ IsValid = $false; Issues = @('$.commit: is missing.') }
        }
        @{
            Id       = 'record-09'
            Title    = 'A JSON string is not a record'
            Design   = 'Release state: the validator must detect damage'
            Kind     = 'Record'
            Json     = '"0.9.0"'
            Expected = @{ IsValid = $false; Issues = @('$: Release record must be a JSON object.') }
        }
    )
}
