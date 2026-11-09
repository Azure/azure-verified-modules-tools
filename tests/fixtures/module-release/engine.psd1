@{
    Area      = 'engine'
    Function  = 'Get-AvmReleaseDecision'
    Scenarios = @(
        @{
            Id     = 'engine-01'
            Title  = 'A labelled human merge starts both timers and waits'
            Design = 'Release timing > Recommended policy'
            Steps  = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('minor') })
                    Expected = @{
                        Status  = 'waiting'
                        Changed = $true
                        Summary = @{
                            BaseVersion            = '0.8.2'
                            Version                = '0.9.0'
                            Increment              = 'minor'
                            PendingPullRequests    = @(101)
                            TriggeringPullRequests = @(101)
                            FirstTriggerAt         = '2026-09-01T10:00:00Z'
                            LastTriggerAt          = '2026-09-01T10:00:00Z'
                            RestartDeadline        = '2026-09-02T10:00:00Z'
                            CapDeadline            = '2026-09-04T10:00:00Z'
                            DueAt                  = '2026-09-02T10:00:00Z'
                            DueBy                  = 'timer'
                            'BlockingIssues#'      = 0
                            'Flags#'               = 0
                        }
                        State   = @{
                            'pending.pullRequests[0].number'          = 101
                            'pending.pullRequests[0].kind'            = 'Human'
                            'pending.pullRequests[0].triggersRelease' = $true
                            'pending.pullRequests[0].triggeredAt'     = '2026-09-01T10:00:00Z'
                            'pending.pullRequests[0].triggeredBy'     = 'merge'
                            'pending.pullRequests[0].versionLabels'   = @('minor')
                            'publication'                             = $null
                        }
                    }
                }
            )
        }
        @{
            Id     = 'engine-02'
            Title  = 'The 24-hour timer publishes a release record and the next run is idempotent'
            Design = 'Publishing a release > Publication cutoff; Release state and recovery'
            Steps  = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('minor') })
                    Expected = @{ Status = 'waiting'; Changed = $true }
                }
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Expected = @{
                        Status  = 'publishing'
                        Changed = $true
                        Actions = @(
                            @{
                                Type            = 'StartPublication'
                                Version         = '0.9.0'
                                PreviousVersion = '0.8.2'
                                Commit          = '0123456789abcdef0123456789abcdef01234567'
                                Trigger         = 'timer'
                                RecordPath      = 'releases/v0.9.0.json'
                                'RecordJson~'   = '"version":\s*"0\.9\.0"'
                                Record          = @{
                                    schemaVersion   = 1
                                    repository      = 'Azure/terraform-azurerm-avm-res-example'
                                    version         = '0.9.0'
                                    previousVersion = '0.8.2'
                                    increment       = 'minor'
                                    commit          = '0123456789abcdef0123456789abcdef01234567'
                                    cutoffAt        = '2026-09-02T10:00:00Z'
                                    trigger         = 'timer'
                                    requestedBy     = $null
                                    notes           = @'
## What's changed

- feat: change 101 (#101)

**Full changelog:** https://github.com/Azure/terraform-azurerm-avm-res-example/compare/v0.8.2...v0.9.0

'@
                                    pullRequests    = @(
                                        @{
                                            number          = 101
                                            title           = 'feat: change 101'
                                            author          = 'alice'
                                            kind            = 'Human'
                                            mergedAt        = '2026-09-01T10:00:00Z'
                                            'mergeCommit~'  = '^0{37}101$'
                                            triggersRelease = $true
                                            versionLabel    = 'minor'
                                            breaking        = $false
                                        }
                                    )
                                }
                            }
                        )
                        Summary = @{ BaseVersion = '0.9.0'; Version = $null; 'TriggeringPullRequests#' = 0 }
                        State   = @{
                            'publication.version'                      = '0.9.0'
                            'publication.previousVersion'              = '0.8.2'
                            'publication.stage'                        = 'cutoff'
                            'publication.trigger'                      = 'timer'
                            'publication.cutoffAt'                     = '2026-09-02T10:00:00Z'
                            'publication.pullRequests[0].number'       = 101
                            'publication.pullRequests[0].versionLabel' = 'minor'
                            'pending.pullRequests#'                    = 0
                        }
                    }
                }
                @{
                    Now      = '2026-09-02T11:00:00Z'
                    Expected = @{ Status = 'publishing'; Changed = $false }
                }
            )
        }
        @{
            Id     = 'engine-03'
            Title  = 'A second merge restarts the 24-hour timer and the highest label wins'
            Design = 'Release timing > Recommended policy; Which PRs trigger a release > Selecting the version'
            Steps  = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Expected = @{ Status = 'waiting'; Summary = @{ Version = '0.8.3'; DueAt = '2026-09-02T10:00:00Z' } }
                }
                @{
                    Now      = '2026-09-02T09:30:00Z'
                    Merge    = @(@{ Number = 102; MergedAt = '2026-09-02T11:00:00+02:00'; Labels = @('minor') })
                    Expected = @{
                        Status  = 'waiting'
                        Changed = $true
                        Summary = @{
                            Version         = '0.9.0'
                            Increment       = 'minor'
                            FirstTriggerAt  = '2026-09-01T10:00:00Z'
                            LastTriggerAt   = '2026-09-02T09:00:00Z'
                            RestartDeadline = '2026-09-03T09:00:00Z'
                            CapDeadline     = '2026-09-04T10:00:00Z'
                            DueAt           = '2026-09-03T09:00:00Z'
                            DueBy           = 'timer'
                        }
                        State   = @{ 'pending.pullRequests[1].mergedAt' = '2026-09-02T09:00:00Z' }
                    }
                }
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Expected = @{ Status = 'waiting'; Changed = $false }
                }
                @{
                    Now      = '2026-09-03T09:00:00Z'
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(@{ Type = 'StartPublication'; Version = '0.9.0'; Trigger = 'timer'; Record = @{ increment = 'minor'; 'pullRequests#' = 2 } })
                    }
                }
            )
        }
        @{
            Id     = 'engine-04'
            Title  = 'The 72-hour cap publishes even while merges keep restarting the timer'
            Design = 'Release timing > Recommended policy'
            Steps  = @(
                @{
                    Now      = '2026-09-03T20:30:00Z'
                    Merge    = @(
                        @{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') }
                        @{ Number = 102; MergedAt = '2026-09-02T09:00:00Z'; Labels = @('patch') }
                        @{ Number = 103; MergedAt = '2026-09-03T08:00:00Z'; Labels = @('patch') }
                        @{ Number = 104; MergedAt = '2026-09-03T20:00:00Z'; Labels = @('patch') }
                    )
                    Expected = @{
                        Status  = 'waiting'
                        Summary = @{
                            Version         = '0.8.3'
                            FirstTriggerAt  = '2026-09-01T10:00:00Z'
                            RestartDeadline = '2026-09-04T20:00:00Z'
                            CapDeadline     = '2026-09-04T10:00:00Z'
                            DueAt           = '2026-09-04T10:00:00Z'
                            DueBy           = 'cap'
                        }
                    }
                }
                @{
                    Now      = '2026-09-04T09:59:59Z'
                    Expected = @{ Status = 'waiting'; Changed = $false }
                }
                @{
                    Now      = '2026-09-04T10:00:00Z'
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(@{ Type = 'StartPublication'; Version = '0.8.3'; Trigger = 'cap'; Record = @{ increment = 'patch'; trigger = 'cap'; 'pullRequests#' = 4 } })
                    }
                }
            )
        }
        @{
            Id     = 'engine-05'
            Title  = 'A timer that ends on Saturday waits until Monday'
            Design = 'Release timing > Recommended policy'
            Steps  = @(
                @{
                    Now      = '2026-09-04T15:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-04T15:00:00Z'; Labels = @('patch') })
                    Expected = @{
                        Status  = 'waiting'
                        Summary = @{
                            RestartDeadline = '2026-09-07T15:00:00Z'
                            CapDeadline     = '2026-09-07T15:00:00Z'
                            DueAt           = '2026-09-07T15:00:00Z'
                            DueBy           = 'timer'
                        }
                    }
                }
                @{
                    Now      = '2026-09-05T15:00:00Z'
                    Expected = @{ Status = 'waiting'; Changed = $false }
                }
                @{
                    Now      = '2026-09-07T14:59:59Z'
                    Expected = @{ Status = 'waiting'; Changed = $false }
                }
                @{
                    Now      = '2026-09-07T15:00:00Z'
                    Expected = @{ Status = 'publishing'; Actions = @(@{ Type = 'StartPublication'; Version = '0.8.3'; Trigger = 'timer' }) }
                }
            )
        }
        @{
            Id     = 'engine-06'
            Title  = 'A cap that ends on Saturday also gets 48 more hours and still wins'
            Design = 'Release timing > Recommended policy'
            Steps  = @(
                @{
                    Now      = '2026-09-04T13:30:00Z'
                    Merge    = @(
                        @{ Number = 101; MergedAt = '2026-09-02T12:00:00Z'; Labels = @('patch') }
                        @{ Number = 102; MergedAt = '2026-09-03T11:00:00Z'; Labels = @('patch') }
                        @{ Number = 103; MergedAt = '2026-09-04T10:00:00Z'; Labels = @('patch') }
                        @{ Number = 104; MergedAt = '2026-09-04T13:00:00Z'; Labels = @('patch') }
                    )
                    Expected = @{
                        Status  = 'waiting'
                        Summary = @{
                            RestartDeadline = '2026-09-07T13:00:00Z'
                            CapDeadline     = '2026-09-07T12:00:00Z'
                            DueAt           = '2026-09-07T12:00:00Z'
                            DueBy           = 'cap'
                        }
                    }
                }
                @{
                    Now      = '2026-09-06T12:00:00Z'
                    Expected = @{ Status = 'waiting'; Changed = $false }
                }
                @{
                    Now      = '2026-09-07T12:00:00Z'
                    Expected = @{ Status = 'publishing'; Actions = @(@{ Type = 'StartPublication'; Version = '0.8.3'; Trigger = 'cap' }) }
                }
            )
        }
        @{
            Id         = 'engine-07'
            Title      = 'A repo-sync merge is flagged, then an owner opt-in starts the timers and publishes it'
            Design     = 'Which PRs trigger a release > Bot PRs that change module code; Opting in a routine bot PR'
            Assumption = 'Repo-sync pull requests never trigger by merge. A post-merge version label from an authorised user is an opt-in that counts as a merge at the label time.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 110; MergedAt = '2026-09-01T10:00:00Z'; Author = 'azure-verified-modules[bot]'; Title = 'chore: run avm pre-commit' })
                    Expected = @{
                        Status  = 'idle'
                        Changed = $true
                        Actions = @(
                            @{
                                Type        = 'FlagPullRequest'
                                PullRequest = 110
                                Flag        = 'automation-module-code'
                                Blocking    = $false
                                Message     = 'Repo-sync pull request #110 changed module code beyond formatting. It does not trigger a release and ships with the next one. A module owner can opt it in with a version label.'
                            }
                        )
                        Summary = @{ PendingPullRequests = @(110); 'TriggeringPullRequests#' = 0; DueAt = $null; Version = $null }
                        State   = @{
                            'pending.pullRequests[0].kind'              = 'Automation'
                            'pending.pullRequests[0].triggersRelease'   = $false
                            'pending.pullRequests[0].moduleCodeChanged' = $true
                            'pending.pullRequests[0].formattingOnly'    = $false
                            'pending.pullRequests[0].flags'             = @('automation-module-code')
                        }
                    }
                }
                @{
                    Now      = '2026-09-01T15:00:00Z'
                    Label    = @(@{ Id = 5001; PullRequest = 110; Label = 'minor'; Actor = 'dave'; At = '2026-09-01T15:00:00Z' })
                    Expected = @{
                        Status  = 'waiting'
                        Changed = $true
                        Actions = @(
                            @{
                                Type        = 'AcceptOptIn'
                                PullRequest = 110
                                Label       = 'minor'
                                Action      = 'labeled'
                                Actor       = 'dave'
                                Reason      = $null
                                Message     = 'Pull request #110 joins the pending release. The opt-in counts as a merge at 2026-09-01T15:00:00Z.'
                            }
                        )
                        Summary = @{
                            Version         = '0.9.0'
                            FirstTriggerAt  = '2026-09-01T15:00:00Z'
                            RestartDeadline = '2026-09-02T15:00:00Z'
                            CapDeadline     = '2026-09-04T15:00:00Z'
                            'Flags#'        = 0
                        }
                        State   = @{
                            'pending.pullRequests[0].triggersRelease'  = $true
                            'pending.pullRequests[0].triggeredAt'      = '2026-09-01T15:00:00Z'
                            'pending.pullRequests[0].triggeredBy'      = 'opt-in'
                            'pending.pullRequests[0].optIn.by'         = 'dave'
                            'pending.pullRequests[0].optIn.at'         = '2026-09-01T15:00:00Z'
                            'pending.pullRequests[0].flags#'           = 0
                            'pending.pullRequests[0].labelChanges#'    = 1
                            'pending.pullRequests[0].versionLabels'    = @('minor')
                            'labelCursor.at'                           = '2026-09-01T15:00:00Z'
                            'labelCursor.id'                           = 5001
                        }
                    }
                }
                @{
                    Now      = '2026-09-02T15:00:00Z'
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(
                            @{
                                Type    = 'StartPublication'
                                Version = '0.9.0'
                                Trigger = 'timer'
                                Record  = @{
                                    'notes~'     = '- chore: run avm pre-commit \(#110\)'
                                    pullRequests = @(@{ number = 110; kind = 'Automation'; author = 'azure-verified-modules[bot]'; triggersRelease = $true; versionLabel = 'minor' })
                                }
                            }
                        )
                    }
                }
            )
        }
        @{
            Id         = 'engine-08'
            Title      = 'Repo-sync merges ride along with the next release and only module-code changes are flagged'
            Design     = 'Which PRs trigger a release > Bot PRs that change module code'
            Assumption = 'A repo-sync pull request whose module files are all formatting-equivalent is not flagged. Riding along pull requests are recorded in the release record but not listed under the change list.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(
                        @{ Number = 110; MergedAt = '2026-09-01T09:00:00Z'; Author = 'azure-verified-modules[bot]'; Title = 'chore: run avm pre-commit' }
                        @{
                            Number       = 112
                            MergedAt     = '2026-09-01T09:30:00Z'
                            Author       = 'azure-verified-modules[bot]'
                            Title        = 'chore: run avm pre-commit (formatting)'
                            ChangedFiles = @(
                                @{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $true }
                                @{ Path = 'modules/sub/variables.tf'; Status = 'modified'; FormatEquivalent = $true }
                            )
                        }
                        @{ Number = 111; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') }
                    )
                    Expected = @{
                        Status  = 'waiting'
                        Actions = @(@{ Type = 'FlagPullRequest'; PullRequest = 110; Flag = 'automation-module-code'; Blocking = $false })
                        Summary = @{
                            PendingPullRequests    = @(110, 111, 112)
                            TriggeringPullRequests = @(111)
                            FirstTriggerAt         = '2026-09-01T10:00:00Z'
                            DueAt                  = '2026-09-02T10:00:00Z'
                            Version                = '0.8.3'
                        }
                        State   = @{
                            'pending.pullRequests[1].number'            = 112
                            'pending.pullRequests[1].kind'              = 'Automation'
                            'pending.pullRequests[1].moduleCodeChanged' = $true
                            'pending.pullRequests[1].formattingOnly'    = $true
                            'pending.pullRequests[1].flags#'            = 0
                        }
                    }
                }
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(
                            @{
                                Type    = 'StartPublication'
                                Version = '0.8.3'
                                Record  = @{
                                    'notes~'     = '(?s)^## What''s changed\n\n- feat: change 111 \(#111\)\n\n\*\*Full changelog:\*\*'
                                    pullRequests = @(
                                        @{ number = 110; triggersRelease = $false; versionLabel = $null }
                                        @{ number = 111; triggersRelease = $true; versionLabel = 'patch' }
                                        @{ number = 112; triggersRelease = $false; versionLabel = $null }
                                    )
                                }
                            }
                        )
                    }
                }
            )
        }
        @{
            Id     = 'engine-09'
            Title  = 'An owner label correction changes the version without restarting timers'
            Design = 'Which PRs trigger a release > Correcting version labels'
            Steps  = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Expected = @{ Status = 'waiting'; Summary = @{ Version = '0.8.3' } }
                }
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Label    = @(
                        @{ Id = 5001; PullRequest = 101; Label = 'patch'; Action = 'unlabeled'; Actor = 'alice'; At = '2026-09-01T10:40:00Z' }
                        @{ Id = 5002; PullRequest = 101; Label = 'minor'; Actor = 'dave'; At = '2026-09-01T10:50:00Z' }
                    )
                    Expected = @{
                        Status  = 'waiting'
                        Changed = $true
                        Summary = @{
                            Version         = '0.9.0'
                            LastTriggerAt   = '2026-09-01T10:00:00Z'
                            RestartDeadline = '2026-09-02T10:00:00Z'
                            DueAt           = '2026-09-02T10:00:00Z'
                        }
                        State   = @{
                            'pending.pullRequests[0].versionLabels'          = @('minor')
                            'pending.pullRequests[0].triggeredBy'            = 'merge'
                            'pending.pullRequests[0].labelChanges#'          = 2
                            'pending.pullRequests[0].labelChanges[0].action' = 'unlabeled'
                            'pending.pullRequests[0].labelChanges[1].actor'  = 'dave'
                            'labelCursor.id'                                 = 5002
                        }
                    }
                }
            )
        }
        @{
            Id         = 'engine-10'
            Title      = 'Conflicting labels block a due release until an owner removes one'
            Design     = 'Which PRs trigger a release > Selecting the version; Correcting version labels'
            Assumption = 'BlockPublication repeats on every run while the release is due and blocked. The I/O layer updates the release issue idempotently.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch', 'minor') })
                    Expected = @{
                        Status  = 'blocked'
                        Actions = @(@{ Type = 'FlagPullRequest'; PullRequest = 101; Flag = 'conflicting-labels'; Blocking = $true; Message = 'Pull request #101 has more than one version label: patch, minor.' })
                        Summary = @{ Version = $null; Increment = $null; BlockingIssues = @(@{ Code = 'conflicting-labels'; PullRequest = 101 }) }
                    }
                }
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Expected = @{
                        Status  = 'blocked'
                        Changed = $false
                        Actions = @(
                            @{
                                Type    = 'BlockPublication'
                                Trigger = 'timer'
                                Issues  = @(@{ Code = 'conflicting-labels'; PullRequest = 101 })
                                Message = 'The release is due, but publication is blocked until these issues are fixed.'
                            }
                        )
                    }
                }
                @{
                    Now      = '2026-09-02T10:15:00Z'
                    Expected = @{ Status = 'blocked'; Changed = $false; Actions = @(@{ Type = 'BlockPublication'; Trigger = 'timer' }) }
                }
                @{
                    Now      = '2026-09-02T10:20:00Z'
                    Label    = @(@{ Id = 5001; PullRequest = 101; Label = 'patch'; Action = 'unlabeled'; Actor = 'alice'; At = '2026-09-02T10:20:00Z' })
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(@{ Type = 'StartPublication'; Version = '0.9.0'; Trigger = 'timer' })
                    }
                }
            )
        }
        @{
            Id     = 'engine-11'
            Title  = 'Label events that are not authorised version-label changes on a pending pull request are ignored'
            Design = 'Which PRs trigger a release > Correcting version labels; Authorisation and security'
            Steps  = @(
                @{
                    Now      = '2026-09-01T11:15:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('minor') })
                    Label    = @(
                        @{ Id = 5000; PullRequest = 101; Label = 'patch'; Actor = 'alice'; At = '2026-09-01T09:30:00Z' }
                        @{ Id = 5001; PullRequest = 999; Label = 'minor'; Actor = 'alice'; At = '2026-09-01T10:30:00Z' }
                        @{ Id = 5002; PullRequest = 101; Label = 'major'; Actor = 'erin'; At = '2026-09-01T10:45:00Z' }
                        @{ Id = 5003; PullRequest = 101; Label = 'patch'; Actor = 'dependabot[bot]'; At = '2026-09-01T11:00:00Z' }
                        @{ Id = 5004; PullRequest = 101; Label = 'documentation'; Actor = 'alice'; At = '2026-09-01T11:15:00Z' }
                    )
                    Expected = @{
                        Status  = 'waiting'
                        Actions = @(
                            @{ Type = 'IgnoreLabelChange'; PullRequest = 999; Label = 'minor'; Action = 'labeled'; Actor = 'alice'; Reason = 'not-pending'; Message = 'Pull request #999 is not part of a pending release. A label change cannot release changes that were already published.' }
                            @{ Type = 'IgnoreLabelChange'; PullRequest = 101; Label = 'major'; Actor = 'erin'; Reason = 'not-owner'; Message = 'Only module owners and the core AVM team can change version labels after merge.' }
                            @{ Type = 'IgnoreLabelChange'; PullRequest = 101; Label = 'patch'; Actor = 'dependabot[bot]'; Reason = 'bot'; Message = 'A version-label change by automation is ignored.' }
                        )
                        Summary = @{ Version = '0.9.0' }
                        State   = @{
                            'pending.pullRequests[0].versionLabels' = @('minor')
                            'pending.pullRequests[0].labelChanges#' = 0
                            'labelCursor.at'                        = '2026-09-01T11:15:00Z'
                            'labelCursor.id'                        = 5004
                        }
                    }
                }
                @{
                    Now      = '2026-09-01T11:30:00Z'
                    Expected = @{ Status = 'waiting'; Changed = $false }
                }
            )
        }
        @{
            Id     = 'engine-12'
            Title  = 'A label change after the cutoff is reported and does not change the release'
            Design = 'Publishing a release > Publication cutoff; Which PRs trigger a release > Correcting version labels'
            Steps  = @(
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Expected = @{ Status = 'publishing'; Actions = @(@{ Type = 'StartPublication'; Version = '0.8.3' }) }
                }
                @{
                    Now      = '2026-09-02T11:00:00Z'
                    Label    = @(
                        @{ Id = 5001; PullRequest = 101; Label = 'minor'; Actor = 'dave'; At = '2026-09-02T10:30:00Z' }
                        @{ Id = 5002; PullRequest = 101; Label = 'major'; Actor = 'erin'; At = '2026-09-02T10:45:00Z' }
                    )
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(
                            @{
                                Type          = 'ReportLabelMismatch'
                                PullRequest   = 101
                                Label         = 'minor'
                                Actor         = 'dave'
                                Reason        = 'after-cutoff'
                                Version       = '0.8.3'
                                RecordedLabel = 'patch'
                                Message       = 'Pull request #101 is in v0.8.3, which was cut off with the ''patch'' label. Label changes after the cutoff do not change that release.'
                            }
                            @{ Type = 'IgnoreLabelChange'; PullRequest = 101; Actor = 'erin'; Reason = 'not-owner' }
                        )
                        State   = @{ 'publication.pullRequests[0].versionLabel' = 'patch'; 'labelCursor.id' = 5002 }
                    }
                }
            )
        }
        @{
            Id     = 'engine-13'
            Title  = 'A hold stops automatic publication until an authorised #Release clears it'
            Design = 'Release issue and commands'
            Steps  = @(
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Comment  = @(@{ Id = 7001; CreatedAt = '2026-09-01T11:00:00Z'; Author = 'alice'; Body = '#DoNotRelease waiting for the provider fix' })
                    Expected = @{
                        Status  = 'held'
                        Actions = @(@{ Type = 'AcknowledgeCommand'; CommentId = 7001; Command = 'DoNotRelease'; Actor = 'alice'; Accepted = $true; Reason = $null; Detail = $null; Message = 'Hold placed. Nothing publishes automatically until someone posts #Release.' })
                        State   = @{
                            'hold.reason'            = 'waiting for the provider fix'
                            'hold.placedBy'          = 'alice'
                            'hold.placedAt'          = '2026-09-01T11:00:00Z'
                            'hold.since'             = '2026-09-01T11:00:00Z'
                            'hold.commentId'         = 7001
                            'commentCursor.createdAt' = '2026-09-01T11:00:00Z'
                            'commentCursor.id'       = 7001
                        }
                    }
                }
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Expected = @{ Status = 'held'; Changed = $false }
                }
                @{
                    Now      = '2026-09-02T12:00:00Z'
                    Merge    = @(@{ Number = 102; MergedAt = '2026-09-02T12:00:00Z'; Labels = @('minor') })
                    Expected = @{ Status = 'held'; Summary = @{ Version = '0.9.0'; DueAt = '2026-09-03T12:00:00Z' } }
                }
                @{
                    Now      = '2026-09-02T13:00:00Z'
                    Comment  = @(@{ Id = 7002; CreatedAt = '2026-09-02T13:00:00Z'; Author = 'carol'; Body = '#Release' })
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7002; Command = 'Release'; Actor = 'carol'; Accepted = $true; Message = 'The hold is cleared. Release requested. Publication starts now.' }
                            @{ Type = 'StartPublication'; Version = '0.9.0'; Trigger = 'release-command'; Record = @{ trigger = 'release-command'; requestedBy = 'carol'; cutoffAt = '2026-09-02T13:00:00Z'; 'pullRequests#' = 2 } }
                        )
                        State   = @{ hold = $null; 'publication.trigger' = 'release-command'; 'pending.releaseRequest' = $null }
                    }
                }
            )
        }
        @{
            Id     = 'engine-14'
            Title  = '#Release publishes immediately, even at the weekend'
            Design = 'Release issue and commands; Release timing > Recommended policy'
            Steps  = @(
                @{
                    Now      = '2026-09-05T09:00:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-04T15:00:00Z'; Labels = @('patch') })
                    Comment  = @(@{ Id = 7001; CreatedAt = '2026-09-05T09:00:00Z'; Author = 'dave'; Body = '#Release' })
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; Command = 'Release'; Actor = 'dave'; Accepted = $true; Message = 'Release requested. Publication starts now.' }
                            @{ Type = 'StartPublication'; Version = '0.8.3'; Trigger = 'release-command'; Record = @{ requestedBy = 'dave'; cutoffAt = '2026-09-05T09:00:00Z' } }
                        )
                    }
                }
            )
        }
        @{
            Id         = 'engine-15'
            Title      = 'An active central freeze holds a due or requested release until it ends'
            Design     = 'Publishing a release > Central release freeze'
            Assumption = '#Release during a freeze is accepted and recorded. Publication starts on the first run after the freeze ends.'
            Facts      = @{ Freeze = 'active' }
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Expected = @{ Status = 'waiting' }
                }
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Expected = @{ Status = 'frozen'; Changed = $false }
                }
                @{
                    Now      = '2026-09-02T11:00:00Z'
                    Comment  = @(@{ Id = 7001; CreatedAt = '2026-09-02T11:00:00Z'; Author = 'alice'; Body = '#Release' })
                    Expected = @{
                        Status  = 'frozen'
                        Actions = @(@{ Type = 'AcknowledgeCommand'; Command = 'Release'; Accepted = $true; Message = 'Release requested. A central release freeze is in effect, so publication waits until it ends.' })
                        State   = @{
                            'pending.releaseRequest.requestedBy' = 'alice'
                            'pending.releaseRequest.requestedAt' = '2026-09-02T11:00:00Z'
                            'pending.releaseRequest.commentId'   = 7001
                        }
                    }
                }
                @{
                    Now      = '2026-09-03T09:00:00Z'
                    Facts    = @{ Freeze = 'none' }
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(@{ Type = 'StartPublication'; Version = '0.8.3'; Trigger = 'release-command'; Record = @{ requestedBy = 'alice'; cutoffAt = '2026-09-03T09:00:00Z' } })
                    }
                }
            )
        }
        @{
            Id         = 'engine-16'
            Title      = 'An unknown freeze state fails closed'
            Design     = 'Publishing a release > Central release freeze'
            Assumption = 'A missing freeze fact means the freeze could not be checked, so publication waits.'
            Facts      = @{ Freeze = $null }
            Steps      = @(
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Expected = @{ Status = 'frozen' }
                }
                @{
                    Now      = '2026-09-02T10:30:00Z'
                    Comment  = @(@{ Id = 7001; CreatedAt = '2026-09-02T10:30:00Z'; Author = 'alice'; Body = '#Release' })
                    Expected = @{
                        Status  = 'frozen'
                        Actions = @(@{ Type = 'AcknowledgeCommand'; Command = 'Release'; Accepted = $true; Message = 'Release requested. The central release freeze could not be checked, so publication waits until it can.' })
                    }
                }
                @{
                    Now      = '2026-09-02T11:00:00Z'
                    Facts    = @{ Freeze = 'unknown' }
                    Expected = @{ Status = 'frozen'; Changed = $false }
                }
                @{
                    Now      = '2026-09-02T11:30:00Z'
                    Facts    = @{ Freeze = 'none' }
                    Expected = @{ Status = 'publishing'; Actions = @(@{ Type = 'StartPublication'; Trigger = 'release-command' }) }
                }
            )
        }
        @{
            Id         = 'engine-17'
            Title      = 'Commands after the cutoff apply to the next release while the cut-off release still publishes'
            Design     = 'Publishing a release > Publication cutoff; Release issue and commands'
            Assumption = 'After the cutoff, #ReleaseNotes is rejected, #Release queues the next release behind the current publication, and #DoNotRelease holds only the changes that are still pending.'
            Steps      = @(
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Expected = @{ Status = 'publishing'; Actions = @(@{ Type = 'StartPublication'; Version = '0.8.3' }) }
                }
                @{
                    Now      = '2026-09-02T10:30:00Z'
                    Comment  = @(@{ Id = 7001; CreatedAt = '2026-09-02T10:30:00Z'; Author = 'alice'; Body = '#ReleaseNotes Late commentary.' })
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(@{ Type = 'AcknowledgeCommand'; Command = 'ReleaseNotes'; Accepted = $false; Reason = 'notes-frozen'; Message = 'The notes for v0.8.3 were frozen at the publication cutoff. Post notes for later changes on the next release issue.' })
                    }
                }
                @{
                    Now      = '2026-09-02T11:00:00Z'
                    Merge    = @(@{ Number = 102; MergedAt = '2026-09-02T11:00:00Z'; Labels = @('minor') })
                    Expected = @{ Status = 'waiting'; Summary = @{ BaseVersion = '0.8.3'; Version = '0.9.0'; DueAt = '2026-09-03T11:00:00Z' } }
                }
                @{
                    Now      = '2026-09-02T11:30:00Z'
                    Comment  = @(@{ Id = 7002; CreatedAt = '2026-09-02T11:30:00Z'; Author = 'dave'; Body = '#Release' })
                    Expected = @{
                        Status  = 'queued'
                        Actions = @(@{ Type = 'AcknowledgeCommand'; Command = 'Release'; Accepted = $true; Message = 'Release requested. Publication starts after v0.8.3 finishes publishing.' })
                        State   = @{ 'pending.releaseRequest.requestedBy' = 'dave'; 'publication.version' = '0.8.3' }
                    }
                }
                @{
                    Now      = '2026-09-02T12:00:00Z'
                    Comment  = @(@{ Id = 7003; CreatedAt = '2026-09-02T12:00:00Z'; Author = 'carol'; Body = '#DoNotRelease wait for 0.8.3 to reach the Registry' })
                    Expected = @{
                        Status  = 'held'
                        Actions = @(@{ Type = 'AcknowledgeCommand'; Command = 'DoNotRelease'; Accepted = $true; Message = 'v0.8.3 was cut off before this hold, so it still publishes. The hold applies to changes that are still pending.' })
                        State   = @{ 'pending.releaseRequest' = $null; 'hold.placedBy' = 'carol'; 'publication.version' = '0.8.3' }
                    }
                }
            )
        }
        @{
            Id         = 'engine-18'
            Title      = 'A missing or invalid base version blocks publication without a pull request flag'
            Design     = 'Which PRs trigger a release > Selecting the version'
            Assumption = 'A repository without a published version blocks. First releases are handled when automation is turned on in a repository (Phase 6).'
            Facts      = @{ LatestVersion = $null }
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Expected = @{
                        Status  = 'blocked'
                        Summary = @{
                            BaseVersion    = $null
                            Version        = $null
                            BlockingIssues = @(@{ Code = 'missing-base-version'; PullRequest = $null; Message = 'No published version is known, so the next version cannot be calculated.' })
                            'Flags#'       = 0
                        }
                    }
                }
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Expected = @{ Status = 'blocked'; Changed = $false; Actions = @(@{ Type = 'BlockPublication'; Trigger = 'timer'; Issues = @(@{ Code = 'missing-base-version' }) }) }
                }
                @{
                    Now      = '2026-09-02T10:05:00Z'
                    Facts    = @{ LatestVersion = 'v0.8' }
                    Expected = @{
                        Status  = 'blocked'
                        Actions = @(@{ Type = 'BlockPublication'; Issues = @(@{ Code = 'invalid-base-version'; PullRequest = $null; Message = 'The latest version ''v0.8'' is not a MAJOR.MINOR.PATCH version.' }) })
                    }
                }
                @{
                    Now      = '2026-09-02T10:10:00Z'
                    Facts    = @{ LatestVersion = '0.8.2' }
                    Expected = @{ Status = 'publishing'; Actions = @(@{ Type = 'StartPublication'; Version = '0.8.3'; PreviousVersion = '0.8.2' }) }
                }
            )
        }
        @{
            Id     = 'engine-19'
            Title  = 'A major label before 1.0.0 blocks until an owner relabels it'
            Design = 'Which PRs trigger a release > Selecting the version'
            Steps  = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('major') })
                    Expected = @{
                        Status  = 'blocked'
                        Actions = @(@{ Type = 'FlagPullRequest'; PullRequest = 101; Flag = 'major-before-1.0'; Blocking = $true; Message = 'Pull request #101 has a major label, but major labels are not allowed before 1.0.0. Use minor for breaking changes.' })
                        State   = @{ 'pending.pullRequests[0].flags' = @('major-before-1.0') }
                    }
                }
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Label    = @(
                        @{ Id = 5001; PullRequest = 101; Label = 'major'; Action = 'unlabeled'; Actor = 'alice'; At = '2026-09-01T10:40:00Z' }
                        @{ Id = 5002; PullRequest = 101; Label = 'minor'; Actor = 'alice'; At = '2026-09-01T10:41:00Z' }
                    )
                    Expected = @{
                        Status  = 'waiting'
                        Summary = @{ Version = '0.9.0'; 'Flags#' = 0; DueAt = '2026-09-02T10:00:00Z' }
                        State   = @{ 'pending.pullRequests[0].flags#' = 0 }
                    }
                }
            )
        }
        @{
            Id         = 'engine-20'
            Title      = 'An unknown main head blocks the cutoff and a valid head is normalised'
            Design     = 'Publishing a release > Publication cutoff'
            Assumption = 'The cutoff commit is the head of main supplied by the I/O layer. The engine does not resolve commits.'
            Facts      = @{ MainHead = $null }
            Steps      = @(
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Expected = @{
                        Status  = 'blocked'
                        Actions = @(@{ Type = 'BlockPublication'; Trigger = 'timer'; Issues = @(@{ Code = 'missing-main-head'; PullRequest = $null; Message = 'The head commit of main is unknown, so the release cannot be cut off.' }) })
                    }
                }
                @{
                    Now      = '2026-09-02T10:05:00Z'
                    Facts    = @{ MainHead = 'not-a-sha' }
                    Expected = @{ Status = 'blocked'; Changed = $false; Actions = @(@{ Type = 'BlockPublication'; Issues = @(@{ Code = 'missing-main-head' }) }) }
                }
                @{
                    Now      = '2026-09-02T10:10:00Z'
                    Facts    = @{ MainHead = ' ABCDEF0123456789ABCDEF0123456789ABCDEF01 ' }
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(@{ Type = 'StartPublication'; Commit = 'abcdef0123456789abcdef0123456789abcdef01'; Record = @{ commit = 'abcdef0123456789abcdef0123456789abcdef01' } })
                        State   = @{ 'publication.commit' = 'abcdef0123456789abcdef0123456789abcdef01' }
                    }
                }
            )
        }
        @{
            Id         = 'engine-21'
            Title      = 'Only a command on the first non-empty line from an authorised human is applied'
            Design     = 'Release issue and commands'
            Assumption = 'Bot comments, quotes, code, indented lines, mid-line mentions, and longer words such as #Releasing are ignored without a reply. The #DoNotRelease reason can follow on the next line.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T12:00:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Comment  = @(
                        @{ Id = 7001; CreatedAt = '2026-09-01T10:10:00Z'; Author = 'github-actions[bot]'; Body = '#Release' }
                        @{ Id = 7002; CreatedAt = '2026-09-01T10:20:00Z'; Author = 'alice'; Body = '> #Release' }
                        @{
                            Id        = 7003
                            CreatedAt = '2026-09-01T10:30:00Z'
                            Author    = 'alice'
                            Body      = @'
```
#Release
```
'@
                        }
                        @{ Id = 7004; CreatedAt = '2026-09-01T10:40:00Z'; Author = 'alice'; Body = 'Please do not #Release yet' }
                        @{ Id = 7005; CreatedAt = '2026-09-01T10:50:00Z'; Author = 'alice'; Body = '    #Release' }
                        @{ Id = 7006; CreatedAt = '2026-09-01T11:00:00Z'; Author = 'alice'; Body = '#Releasing soon' }
                        @{ Id = 7007; CreatedAt = '2026-09-01T11:10:00Z'; Author = 'erin'; Body = '#Release' }
                        @{ Id = 7008; CreatedAt = '2026-09-01T11:20:00Z'; Author = 'alice'; Body = '#DoNotRelease' }
                        @{
                            Id        = 7009
                            CreatedAt = '2026-09-01T11:30:00Z'
                            Author    = 'dave'
                            Body      = @'

#donotrelease
Waiting for the provider fix.
'@
                        }
                    )
                    Expected = @{
                        Status  = 'held'
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7007; Command = 'Release'; Actor = 'erin'; Accepted = $false; Reason = 'not-authorized'; Message = 'Only module owners and the core AVM team can use #Release.' }
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7008; Command = 'DoNotRelease'; Actor = 'alice'; Accepted = $false; Reason = 'missing-reason'; Message = 'Add a reason after #DoNotRelease, for example: #DoNotRelease waiting for the provider fix.' }
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7009; Command = 'DoNotRelease'; Actor = 'dave'; Accepted = $true }
                        )
                        State   = @{ 'hold.reason' = 'Waiting for the provider fix.'; 'hold.placedBy' = 'dave'; 'commentCursor.id' = 7009 }
                    }
                }
            )
        }
        @{
            Id         = 'engine-22'
            Title      = 'Commands with nothing pending are rejected or only clear a hold'
            Design     = 'Release issue and commands'
            Assumption = '#Release with nothing pending clears a hold if one exists and is otherwise rejected.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:00:00Z'
                    Comment  = @(
                        @{ Id = 7001; CreatedAt = '2026-09-01T09:00:00Z'; Author = 'alice'; Body = '#Release' }
                        @{ Id = 7002; CreatedAt = '2026-09-01T09:10:00Z'; Author = 'alice'; Body = '#ReleaseNotes Hello.' }
                    )
                    Expected = @{
                        Status  = 'idle'
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7001; Accepted = $false; Reason = 'nothing-to-release'; Message = 'No changes are waiting to be released.' }
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7002; Accepted = $false; Reason = 'no-pending-release'; Message = 'No release is pending, so there are no release notes to edit.' }
                        )
                    }
                }
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Comment  = @(@{ Id = 7003; CreatedAt = '2026-09-01T10:30:00Z'; Author = 'dave'; Body = '#DoNotRelease migration in progress' })
                    Expected = @{ Status = 'held'; Actions = @(@{ Type = 'AcknowledgeCommand'; CommentId = 7003; Accepted = $true }) }
                }
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Comment  = @(@{ Id = 7004; CreatedAt = '2026-09-01T11:00:00Z'; Author = 'carol'; Body = '#Release' })
                    Expected = @{
                        Status  = 'idle'
                        Actions = @(@{ Type = 'AcknowledgeCommand'; CommentId = 7004; Accepted = $true; Reason = $null; Message = 'The hold is cleared. No changes are waiting to be released.' })
                        State   = @{ hold = $null; 'pending.releaseRequest' = $null }
                    }
                }
            )
        }
        @{
            Id         = 'engine-23'
            Title      = '#DoNotRelease cancels a release request and a second hold keeps its start time'
            Design     = 'Release issue and commands'
            Assumption = 'A later #DoNotRelease updates the reason and author but keeps the original hold start time.'
            Facts      = @{ Freeze = 'active' }
            Steps      = @(
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Comment  = @(@{ Id = 7001; CreatedAt = '2026-09-01T11:00:00Z'; Author = 'alice'; Body = '#Release' })
                    Expected = @{ Status = 'frozen'; Actions = @(@{ Type = 'AcknowledgeCommand'; Accepted = $true }); State = @{ 'pending.releaseRequest.requestedBy' = 'alice' } }
                }
                @{
                    Now      = '2026-09-01T11:30:00Z'
                    Comment  = @(@{ Id = 7002; CreatedAt = '2026-09-01T11:30:00Z'; Author = 'dave'; Body = '#DoNotRelease provider regression' })
                    Expected = @{
                        Status  = 'held'
                        Actions = @(@{ Type = 'AcknowledgeCommand'; CommentId = 7002; Accepted = $true; Message = 'Hold placed. Nothing publishes automatically until someone posts #Release.' })
                        State   = @{ 'pending.releaseRequest' = $null; 'hold.since' = '2026-09-01T11:30:00Z'; 'hold.placedBy' = 'dave' }
                    }
                }
                @{
                    Now      = '2026-09-01T12:00:00Z'
                    Comment  = @(@{ Id = 7003; CreatedAt = '2026-09-01T12:00:00Z'; Author = 'carol'; Body = '#DoNotRelease still investigating' })
                    Expected = @{
                        Status  = 'held'
                        Actions = @(@{ Type = 'AcknowledgeCommand'; CommentId = 7003; Accepted = $true })
                        State   = @{
                            'hold.since'     = '2026-09-01T11:30:00Z'
                            'hold.placedAt'  = '2026-09-01T12:00:00Z'
                            'hold.placedBy'  = 'carol'
                            'hold.reason'    = 'still investigating'
                            'hold.commentId' = 7003
                        }
                    }
                }
            )
        }
        @{
            Id         = 'engine-24'
            Title      = 'A second #Release keeps the first request'
            Design     = 'Release issue and commands'
            Assumption = 'The first accepted #Release is the recorded requester until the release publishes or a hold cancels it.'
            Facts      = @{ Freeze = 'active' }
            Steps      = @(
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Comment  = @(
                        @{ Id = 7001; CreatedAt = '2026-09-01T10:30:00Z'; Author = 'alice'; Body = '#Release' }
                        @{ Id = 7002; CreatedAt = '2026-09-01T10:45:00Z'; Author = 'carol'; Body = '#release please' }
                    )
                    Expected = @{
                        Status  = 'frozen'
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7001; Accepted = $true; Message = 'Release requested. A central release freeze is in effect, so publication waits until it ends.' }
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7002; Command = 'Release'; Accepted = $true; Message = 'A release was already requested. A central release freeze is in effect, so publication waits until it ends.' }
                        )
                        State   = @{ 'pending.releaseRequest.requestedBy' = 'alice'; 'pending.releaseRequest.commentId' = 7001 }
                    }
                }
                @{
                    Now      = '2026-09-01T12:00:00Z'
                    Facts    = @{ Freeze = 'none' }
                    Expected = @{ Status = 'publishing'; Actions = @(@{ Type = 'StartPublication'; Trigger = 'release-command'; Record = @{ requestedBy = 'alice' } }) }
                }
            )
        }
        @{
            Id         = 'engine-25'
            Title      = 'A breaking override keeps declared changes visible and a later breaking change is listed below it'
            Design     = 'Breaking changes and release notes > Composing release notes; Editing release notes on the release issue'
            Assumption = 'The override covers the breaking pull requests declared when it was posted. A breaking pull request merged later is flagged, and its entry is listed below the override.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(
                        @{
                            Number   = 142
                            MergedAt = '2026-09-01T10:00:00Z'
                            Title    = 'feat!: rename `name` input'
                            Labels   = @('minor')
                            Breaking = @{ WhatChanges = 'The `name` input is renamed to `display_name`.'; RequiredUpgrade = 'Rename `name` to `display_name` in module calls.' }
                        }
                    )
                    Comment  = @(
                        @{
                            Id        = 7001
                            CreatedAt = '2026-09-01T10:30:00Z'
                            Author    = 'alice'
                            Body      = @'
#ReleaseNotes
## Breaking changes

The `name` input is now `display_name` (#142). Update every module call.

## Notes from maintainers

This release prepares for 1.0.0.
'@
                        }
                    )
                    Expected = @{
                        Status  = 'waiting'
                        Actions = @(@{ Type = 'AcknowledgeCommand'; CommentId = 7001; Command = 'ReleaseNotes'; Actor = 'alice'; Accepted = $true; Reason = $null; Detail = $null; Message = 'Release notes updated.' })
                        Summary = @{
                            DeclaredBreakingPullRequests = @(142)
                            'LateBreakingPullRequests#'  = 0
                            BreakingText                 = 'The `name` input is now `display_name` (#142). Update every module call.'
                        }
                        State   = @{
                            'pending.notes.breakingOverride.text'                = 'The `name` input is now `display_name` (#142). Update every module call.'
                            'pending.notes.breakingOverride.coveredPullRequests' = @(142)
                            'pending.notes.breakingOverride.setBy'               = 'alice'
                            'pending.notes.breakingOverride.setAt'               = '2026-09-01T10:30:00Z'
                            'pending.notes.commentary.text'                      = 'This release prepares for 1.0.0.'
                            'pending.notes.commentary.setBy'                     = 'alice'
                            'pending.pullRequests[0].breaking.declared'          = $true
                            'pending.pullRequests[0].breaking.whatChanges'       = 'The `name` input is renamed to `display_name`.'
                        }
                    }
                }
                @{
                    Now      = '2026-09-01T13:30:00Z'
                    Merge    = @(
                        @{
                            Number   = 150
                            MergedAt = '2026-09-01T13:00:00Z'
                            Title    = 'feat!: remove the legacy output'
                            Labels   = @('minor')
                            Breaking = @{ WhatChanges = 'The `legacy` output is removed.'; RequiredUpgrade = 'Read `resource` instead.' }
                        }
                    )
                    Expected = @{
                        Status  = 'waiting'
                        Actions = @(@{ Type = 'FlagPullRequest'; PullRequest = 150; Flag = 'late-breaking-change'; Blocking = $false; Message = 'Pull request #150 declared a breaking change after the ''Breaking changes'' text was overridden. Its entry is listed below the override.' })
                        Summary = @{
                            DeclaredBreakingPullRequests = @(142, 150)
                            LateBreakingPullRequests     = @(150)
                            DueAt                        = '2026-09-02T13:00:00Z'
                            BreakingText                 = @'
The `name` input is now `display_name` (#142). Update every module call.

- **What changes:** The `legacy` output is removed. (#150)
- **Required upgrade:** Read `resource` instead.
'@
                        }
                        State   = @{
                            'pending.pullRequests[1].flags'                      = @('late-breaking-change')
                            'pending.notes.breakingOverride.coveredPullRequests' = @(142)
                        }
                    }
                }
                @{
                    Now      = '2026-09-02T13:00:00Z'
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(
                            @{
                                Type    = 'StartPublication'
                                Version = '0.9.0'
                                Trigger = 'timer'
                                Record  = @{
                                    notes        = @'
## Breaking changes

The `name` input is now `display_name` (#142). Update every module call.

- **What changes:** The `legacy` output is removed. (#150)
- **Required upgrade:** Read `resource` instead.

## Notes from maintainers

This release prepares for 1.0.0.

## What's changed

- feat!: rename `name` input (#142)
- feat!: remove the legacy output (#150)

**Full changelog:** https://github.com/Azure/terraform-azurerm-avm-res-example/compare/v0.8.2...v0.9.0

'@
                                    pullRequests = @(
                                        @{ number = 142; breaking = $true; versionLabel = 'minor' }
                                        @{ number = 150; breaking = $true; versionLabel = 'minor' }
                                    )
                                }
                            }
                        )
                    }
                }
            )
        }
        @{
            Id         = 'engine-26'
            Title      = 'Placeholder breaking details block until a #ReleaseNotes override covers the pull request'
            Design     = 'Breaking changes and release notes > Breaking-change details; Editing release notes on the release issue'
            Assumption = 'Unchanged placeholders count as missing details. They render as _Not provided._ and block publication until an accepted override mentions the pull request.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('minor'); Breaking = @{ WhatChanges = 'Describe what breaks for consumers.'; RequiredUpgrade = 'Describe what consumers must change.' } })
                    Expected = @{
                        Status  = 'blocked'
                        Actions = @(
                            @{
                                Type        = 'FlagPullRequest'
                                PullRequest = 101
                                Flag        = 'breaking-details-invalid'
                                Blocking    = $true
                                Message     = 'Pull request #101 declares a breaking change, but its details are incomplete (what-changes-placeholder, required-upgrade-placeholder). Post a #ReleaseNotes comment whose ''Breaking changes'' section covers #101.'
                            }
                        )
                        Summary = @{
                            DeclaredBreakingPullRequests = @(101)
                            DueAt                        = '2026-09-02T10:00:00Z'
                            BreakingText                 = @'
- **What changes:** _Not provided._ (#101)
- **Required upgrade:** _Not provided._
'@
                        }
                        State   = @{
                            'pending.pullRequests[0].breaking.declared'        = $true
                            'pending.pullRequests[0].breaking.whatChanges'     = $null
                            'pending.pullRequests[0].breaking.requiredUpgrade' = $null
                            'pending.pullRequests[0].breaking.issues'          = @('what-changes-placeholder', 'required-upgrade-placeholder')
                        }
                    }
                }
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Comment  = @(
                        @{
                            Id        = 7001
                            CreatedAt = '2026-09-01T10:40:00Z'
                            Author    = 'alice'
                            Body      = @'
#ReleaseNotes
## Breaking changes

See the upgrade guide.
'@
                        }
                        @{
                            Id        = 7002
                            CreatedAt = '2026-09-01T10:45:00Z'
                            Author    = 'alice'
                            Body      = @'
#ReleaseNotes
## What's changed

- Nothing to see.
'@
                        }
                        @{
                            Id        = 7003
                            CreatedAt = '2026-09-01T10:50:00Z'
                            Author    = 'alice'
                            Body      = @'
#ReleaseNotes
## Breaking changes

## Notes from maintainers

Upgrade with care.
'@
                        }
                        @{
                            Id        = 7004
                            CreatedAt = '2026-09-01T11:00:00Z'
                            Author    = 'dave'
                            Body      = @'
#ReleaseNotes
## Breaking changes

The `legacy_name` input is removed (#101). Use `name` instead.
'@
                        }
                    )
                    Expected = @{
                        Status  = 'waiting'
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7001; Accepted = $false; Reason = 'invalid-notes'; Detail = 'missing-breaking-pull-request'; Message = 'The ''Breaking changes'' section must mention every declared breaking pull request. Missing: #101.' }
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7002; Accepted = $false; Reason = 'invalid-notes'; Detail = 'change-list-not-editable'; Message = 'The ''What''s changed'' list comes from merged pull requests and cannot be edited.' }
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7003; Accepted = $false; Reason = 'invalid-notes'; Detail = 'empty-breaking-changes'; Message = 'The ''Breaking changes'' section cannot be empty. Known breaking changes must stay visible.' }
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7004; Actor = 'dave'; Accepted = $true; Message = 'Release notes updated.' }
                        )
                        Summary = @{ 'BlockingIssues#' = 0; 'Flags#' = 0; BreakingText = 'The `legacy_name` input is removed (#101). Use `name` instead.' }
                        State   = @{
                            'pending.pullRequests[0].flags#'                     = 0
                            'pending.notes.commentary'                           = $null
                            'pending.notes.breakingOverride.coveredPullRequests' = @(101)
                        }
                    }
                }
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(@{ Type = 'StartPublication'; Version = '0.9.0'; Record = @{ 'notes~' = '^## Breaking changes\n\nThe `legacy_name` input is removed \(#101\)\. Use `name` instead\.\n\n## What''s changed\n\n- feat: change 101 \(#101\)\n' } })
                    }
                }
            )
        }
        @{
            Id         = 'engine-27'
            Title      = 'A facts-contract violation throws and the run persists nothing'
            Design     = 'Release state and recovery'
            Assumption = 'The I/O layer must supply well-formed facts. A violation throws an ArgumentException, so the run changes no state and posts nothing.'
            Steps      = @(
                @{ Now = '2026-09-01T11:00:00Z'; Facts = @{ Repository = 'example' }; Throws = '^Repository ''example'' must be ''owner/name''\.$' }
                @{ Now = '2026-09-01T11:00:00'; Throws = '^Now ''2026-09-01T11:00:00'' must be an ISO-8601 timestamp with an offset, such as 2026-09-07T09:00:00Z\.$' }
                @{ Now = '2026-09-01T11:00:00Z'; Facts = @{ Freeze = 'paused' }; Throws = '^Freeze ''paused'' must be ''none'', ''active'', or ''unknown''\.$' }
                @{
                    Now    = '2026-09-01T11:00:00Z'
                    Merge  = @(
                        @{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') }
                        @{ Number = 101; MergedAt = '2026-09-01T10:30:00Z'; Labels = @('patch') }
                    )
                    Throws = '^Pull request #101 is listed more than once\.$'
                }
                @{
                    Now    = '2026-09-01T11:00:00Z'
                    Merge  = @(@{ Number = 102; MergedAt = '2026-09-01T11:30:00Z'; Labels = @('patch') })
                    Throws = '^Pull request #102 merged after Now\.$'
                }
                @{
                    Now    = '2026-09-01T11:00:00Z'
                    Merge  = @(@{ Number = 103; MergedAt = '2026-09-01T10:00:00Z'; MergeCommit = 'abc123'; Labels = @('patch') })
                    Throws = '^Pull request #103 MergeCommit must be a 40-character commit SHA\.$'
                }
                @{
                    Now    = '2026-09-01T11:00:00Z'
                    Merge  = @(@{ Number = 104; MergedAt = '2026-09-01T10:00:00Z'; Labels = @(@{ Name = 'patch'; AddedBy = 'alice'; AddedAt = '2026-09-01T10:05:00Z' }) })
                    Throws = '^Pull request #104 label ''patch'' was added after the merge\. Labels must be the labels present at merge\.$'
                }
                @{
                    Now    = '2026-09-01T11:00:00Z'
                    Merge  = @(@{ Number = 105; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch'); ChangedFiles = @(@{ Path = 'main.tf'; Status = 'deleted'; FormatEquivalent = $false }) })
                    Throws = '^Pull request #105 changed file Status ''deleted'' is not a GitHub file status\.$'
                }
                @{
                    Now    = '2026-09-01T11:00:00Z'
                    Label  = @(
                        @{ Id = 5001; PullRequest = 101; Label = 'patch'; Actor = 'alice'; At = '2026-09-01T10:00:00Z' }
                        @{ Id = 5001; PullRequest = 101; Label = 'minor'; Actor = 'alice'; At = '2026-09-01T10:10:00Z' }
                    )
                    Throws = '^Label event 5001 is listed more than once\.$'
                }
                @{
                    Now    = '2026-09-01T11:00:00Z'
                    Label  = @(@{ Id = 5002; PullRequest = 101; Label = 'patch'; Actor = 'alice'; At = '2026-09-01T11:30:00Z' })
                    Throws = '^Label event 5002 happened after Now\.$'
                }
                @{
                    Now    = '2026-09-01T11:00:00Z'
                    Label  = @(@{ Id = 5003; PullRequest = 101; Label = 'patch'; Action = 'added'; Actor = 'alice'; At = '2026-09-01T10:00:00Z' })
                    Throws = '^Label event 5003 Action must be ''labeled'' or ''unlabeled''\.$'
                }
                @{
                    Now     = '2026-09-01T11:00:00Z'
                    Comment = @(
                        @{ Id = 7001; CreatedAt = '2026-09-01T10:00:00Z'; Author = 'alice'; Body = '#Release' }
                        @{ Id = 7001; CreatedAt = '2026-09-01T10:10:00Z'; Author = 'alice'; Body = '#Release' }
                    )
                    Throws  = '^Comment 7001 is listed more than once\.$'
                }
                @{
                    Now     = '2026-09-01T11:00:00Z'
                    Comment = @(@{ Id = 7002; CreatedAt = '2026-09-01T11:30:00Z'; Author = 'alice'; Body = '#Release' })
                    Throws  = '^Comment 7002 was created after Now\.$'
                }
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Expected = @{ Status = 'idle'; Changed = $true; State = @{ 'pending.pullRequests#' = 0; hold = $null; labelCursor = $null; commentCursor = $null } }
                }
            )
        }
        @{
            Id         = 'engine-28'
            Title      = 'Damaged or missing state stops the engine until a maintainer recovers it'
            Design     = 'Release state and recovery'
            Assumption = 'Missing state fails closed unless the caller asks to initialise it. Initialisation is refused when state already exists.'
            Steps      = @(
                @{
                    Now       = '2026-09-01T11:00:00Z'
                    StateJson = '{"schemaVersion":1,'
                    Expected  = @{
                        Status  = 'damaged'
                        Changed = $false
                        Summary = $null
                        Actions = @(@{ Type = 'ReportDamagedState'; 'Issues~' = '^\$: '; Message = 'The release state is damaged, so publication stopped. A maintainer must recover it.' })
                    }
                }
                @{
                    Now       = '2026-09-01T11:00:00Z'
                    StateJson = '{"commentCursor":null,"hold":null,"labelCursor":null,"pending":{"notes":{"breakingOverride":null,"commentary":null},"pullRequests":[],"releaseRequest":null},"publication":null,"releaseIssue":null,"repository":"Azure/terraform-azurerm-avm-res-other","schemaVersion":1}'
                    Expected  = @{
                        Status  = 'damaged'
                        Changed = $false
                        Actions = @(@{ Type = 'ReportDamagedState'; Issues = @('$.repository: state belongs to ''Azure/terraform-azurerm-avm-res-other'', not ''Azure/terraform-azurerm-avm-res-example''.') })
                    }
                }
                @{
                    Now       = '2026-09-01T11:00:00Z'
                    StateJson = '{"commentCursor":null,"hold":null,"labelCursor":null,"pending":{"notes":{"breakingOverride":null,"commentary":null},"pullRequests":[],"releaseRequest":null},"publication":null,"releaseIssue":null,"repository":"Azure/terraform-azurerm-avm-res-example","schemaVersion":2}'
                    Expected  = @{
                        Status  = 'damaged'
                        Changed = $false
                        Actions = @(@{ Type = 'ReportDamagedState'; Issues = @('$.schemaVersion: version ''2'' is not supported. Expected 1.') })
                    }
                }
                @{
                    Now       = '2026-09-01T11:00:00Z'
                    StateJson = '{"commentCursor":null,"hold":"yes","labelCursor":null,"pending":{"notes":{"breakingOverride":null,"commentary":null},"pullRequests":[],"releaseRequest":null},"publication":null,"releaseIssue":null,"repository":"Azure/terraform-azurerm-avm-res-example","schemaVersion":1}'
                    Expected  = @{ Status = 'damaged'; Changed = $false; Actions = @(@{ Type = 'ReportDamagedState'; 'Issues~' = '^\$: release state does not match avm-release-state\.schema\.json\.' }) }
                }
                @{
                    Now       = '2026-09-01T11:00:00Z'
                    StateJson = $null
                    Expected  = @{ Status = 'damaged'; Changed = $false; Actions = @(@{ Type = 'ReportDamagedState'; Issues = @('$: the release state is missing.') }) }
                }
                @{
                    Now        = '2026-09-01T11:00:00Z'
                    StateJson  = '{"commentCursor":null,"hold":null,"labelCursor":null,"pending":{"notes":{"breakingOverride":null,"commentary":null},"pullRequests":[],"releaseRequest":null},"publication":null,"releaseIssue":null,"repository":"Azure/terraform-azurerm-avm-res-example","schemaVersion":1}'
                    Initialize = $true
                    Throws     = '^Initialize applies only when no release state exists\.$'
                }
                @{
                    Now       = '2026-09-01T11:00:00Z'
                    StateJson = '{"commentCursor":null,"hold":null,"labelCursor":null,"pending":{"notes":{"breakingOverride":null,"commentary":null},"pullRequests":[],"releaseRequest":null},"publication":null,"releaseIssue":null,"repository":"Azure/terraform-azurerm-avm-res-example","schemaVersion":1}'
                    Expected  = @{ Status = 'idle'; Changed = $false; Summary = @{ 'PendingPullRequests#' = 0 } }
                }
            )
        }
        @{
            Id         = 'engine-29'
            Title      = 'Unknown owners leave only the core AVM team authorised'
            Design     = 'Authorisation and security'
            Assumption = 'When metadata.json owners are unknown, only the core AVM team is authorised. Write access alone never authorises.'
            Facts      = @{ Authorization = @{ Owners = $null } }
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Comment  = @(
                        @{ Id = 7001; CreatedAt = '2026-09-01T10:10:00Z'; Author = 'alice'; Body = '#DoNotRelease owners unknown' }
                        @{ Id = 7002; CreatedAt = '2026-09-01T10:15:00Z'; Author = 'dave'; Body = '#Release' }
                        @{ Id = 7003; CreatedAt = '2026-09-01T10:20:00Z'; Author = 'carol'; Body = '#DoNotRelease metadata.json could not be read' }
                    )
                    Label    = @(@{ Id = 5001; PullRequest = 101; Label = 'minor'; Actor = 'alice'; At = '2026-09-01T10:25:00Z' })
                    Expected = @{
                        Status  = 'held'
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7001; Command = 'DoNotRelease'; Actor = 'alice'; Accepted = $false; Reason = 'not-authorized'; Message = 'Only module owners and the core AVM team can use #DoNotRelease.' }
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7002; Command = 'Release'; Actor = 'dave'; Accepted = $false; Reason = 'not-authorized'; Message = 'Only module owners and the core AVM team can use #Release.' }
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7003; Command = 'DoNotRelease'; Actor = 'carol'; Accepted = $true }
                            @{ Type = 'IgnoreLabelChange'; PullRequest = 101; Label = 'minor'; Actor = 'alice'; Reason = 'not-owner' }
                        )
                        Summary = @{ Version = '0.8.3' }
                        State   = @{ 'hold.placedBy' = 'carol'; 'hold.reason' = 'metadata.json could not be read'; 'pending.pullRequests[0].versionLabels' = @('patch') }
                    }
                }
            )
        }
        @{
            Id         = 'engine-30'
            Title      = 'The core AVM team is configurable'
            Design     = 'Authorisation and security'
            Assumption = 'The core team defaults to azure-verified-modules-engineering-owners. A configured core team replaces the default, so members of the default team lose core rights.'
            Facts      = @{ Authorization = @{ CoreTeam = 'Azure/avm-release-admins'; ActorTeams = @{ frank = @('Azure/avm-release-admins') } } }
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Comment  = @(
                        @{ Id = 7001; CreatedAt = '2026-09-01T10:10:00Z'; Author = 'carol'; Body = '#DoNotRelease checking the provider' }
                        @{ Id = 7002; CreatedAt = '2026-09-01T10:20:00Z'; Author = 'frank'; Body = '#DoNotRelease checking the provider' }
                    )
                    Expected = @{
                        Status  = 'held'
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7001; Actor = 'carol'; Accepted = $false; Reason = 'not-authorized' }
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7002; Actor = 'frank'; Accepted = $true }
                        )
                        State   = @{ 'hold.placedBy' = 'frank' }
                    }
                }
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Comment  = @(@{ Id = 7003; CreatedAt = '2026-09-01T11:00:00Z'; Author = 'alice'; Body = '#Release' })
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7003; Accepted = $true; Message = 'The hold is cleared. Release requested. Publication starts now.' }
                            @{ Type = 'StartPublication'; Version = '0.8.3'; Trigger = 'release-command'; Record = @{ requestedBy = 'alice' } }
                        )
                        State   = @{ hold = $null }
                    }
                }
            )
        }
        @{
            Id         = 'engine-31'
            Title      = 'Version labels on a routine bot pull request at merge are opt-ins only when an authorised human added them'
            Design     = 'Which PRs trigger a release > Opting in a routine bot PR; Authorisation and security'
            Assumption = 'A label added before the merge by an authorised human is an opt-in. The opt-in records the label time, but the timers start at the merge.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(
                        @{
                            Number       = 122
                            MergedAt     = '2026-09-01T09:40:00Z'
                            Author       = 'dependabot[bot]'
                            Title        = 'chore(deps): bump actions/checkout'
                            ChangedFiles = @(@{ Path = '.github/workflows/test.yml'; Status = 'modified'; FormatEquivalent = $false })
                            Labels       = @(@{ Name = 'patch'; AddedBy = 'dependabot[bot]'; AddedAt = '2026-09-01T09:35:00Z' })
                        }
                        @{
                            Number       = 123
                            MergedAt     = '2026-09-01T09:50:00Z'
                            Author       = 'dependabot[bot]'
                            Title        = 'chore(deps): bump the docs tool'
                            ChangedFiles = @(@{ Path = 'README.md'; Status = 'modified'; FormatEquivalent = $false })
                            Labels       = @(@{ Name = 'patch'; AddedBy = 'erin'; AddedAt = '2026-09-01T09:45:00Z' })
                        }
                        @{
                            Number       = 121
                            MergedAt     = '2026-09-01T10:00:00Z'
                            Author       = 'dependabot[bot]'
                            Title        = 'chore(deps): bump azurerm to 4.1.0'
                            ChangedFiles = @(@{ Path = 'terraform.tf'; Status = 'modified'; FormatEquivalent = $false })
                            Labels       = @(@{ Name = 'patch'; AddedBy = 'dave'; AddedAt = '2026-09-01T09:30:00Z' })
                        }
                    )
                    Expected = @{
                        Status  = 'waiting'
                        Actions = @(
                            @{ Type = 'IgnoreLabelChange'; PullRequest = 122; Label = 'patch'; Action = 'labeled'; Actor = 'dependabot[bot]'; Reason = 'bot'; Message = 'A version label added by automation is not an opt-in.' }
                            @{ Type = 'IgnoreLabelChange'; PullRequest = 123; Label = 'patch'; Action = 'labeled'; Actor = 'erin'; Reason = 'not-owner'; Message = 'Only module owners and the core AVM team can opt in a bot pull request.' }
                        )
                        Summary = @{
                            PendingPullRequests    = @(121, 122, 123)
                            TriggeringPullRequests = @(121)
                            Version                = '0.8.3'
                            FirstTriggerAt         = '2026-09-01T10:00:00Z'
                            DueAt                  = '2026-09-02T10:00:00Z'
                            'Flags#'               = 0
                        }
                        State   = @{
                            'pending.pullRequests[0].number'          = 122
                            'pending.pullRequests[0].kind'            = 'RoutineBot'
                            'pending.pullRequests[0].triggersRelease' = $false
                            'pending.pullRequests[0].versionLabels#'  = 0
                            'pending.pullRequests[1].triggersRelease' = $false
                            'pending.pullRequests[2].number'          = 121
                            'pending.pullRequests[2].triggersRelease' = $true
                            'pending.pullRequests[2].triggeredBy'     = 'opt-in'
                            'pending.pullRequests[2].triggeredAt'     = '2026-09-01T10:00:00Z'
                            'pending.pullRequests[2].optIn.by'        = 'dave'
                            'pending.pullRequests[2].optIn.at'        = '2026-09-01T09:30:00Z'
                            'pending.pullRequests[2].versionLabels'   = @('patch')
                        }
                    }
                }
            )
        }
        @{
            Id         = 'engine-32'
            Title      = 'A routine bot pull request that changes module code needs a version label, and an owner can add it after merge'
            Design     = 'Which PRs trigger a release > Bot PRs that change module code; Correcting version labels'
            Assumption = 'A routine bot pull request that changes module code beyond formatting triggers like a human merge. Without a version label it blocks publication. A later owner label is a correction, so the timers keep the merge time.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 131; MergedAt = '2026-09-01T10:00:00Z'; Author = 'dependabot[bot]'; Title = 'chore(deps): bump the azapi provider' })
                    Expected = @{
                        Status  = 'blocked'
                        Actions = @(@{ Type = 'FlagPullRequest'; PullRequest = 131; Flag = 'missing-label'; Blocking = $true; Message = 'Pull request #131 has no version label.' })
                        Summary = @{ TriggeringPullRequests = @(131); Version = $null; DueAt = '2026-09-02T10:00:00Z' }
                        State   = @{
                            'pending.pullRequests[0].kind'              = 'RoutineBot'
                            'pending.pullRequests[0].moduleCodeChanged' = $true
                            'pending.pullRequests[0].triggersRelease'   = $true
                            'pending.pullRequests[0].triggeredBy'       = 'merge'
                            'pending.pullRequests[0].flags'             = @('missing-label')
                        }
                    }
                }
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Label    = @(@{ Id = 5001; PullRequest = 131; Label = 'patch'; Actor = 'alice'; At = '2026-09-01T10:45:00Z' })
                    Expected = @{
                        Status  = 'waiting'
                        Changed = $true
                        Summary = @{ Version = '0.8.3'; 'Flags#' = 0; LastTriggerAt = '2026-09-01T10:00:00Z'; DueAt = '2026-09-02T10:00:00Z' }
                        State   = @{
                            'pending.pullRequests[0].versionLabels' = @('patch')
                            'pending.pullRequests[0].triggeredBy'   = 'merge'
                            'pending.pullRequests[0].optIn'         = $null
                            'pending.pullRequests[0].flags#'        = 0
                        }
                    }
                }
            )
        }
        @{
            Id         = 'engine-33'
            Title      = 'Every human merge triggers, including documentation-only and formatting-only changes'
            Design     = 'Which PRs trigger a release'
            Assumption = 'Every human pull request triggers and needs a version label. The module-code and formatting-only classification only changes routine bot and repo-sync handling.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(
                        @{ Number = 141; MergedAt = '2026-09-01T10:00:00Z'; Title = 'docs: clarify the example'; Labels = @('patch'); ChangedFiles = @(@{ Path = 'README.md'; Status = 'modified'; FormatEquivalent = $false }) }
                        @{ Number = 142; MergedAt = '2026-09-01T10:10:00Z'; Title = 'style: format main.tf'; Labels = @('patch'); ChangedFiles = @(@{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $true }) }
                        @{ Number = 143; MergedAt = '2026-09-01T10:20:00Z'; Title = 'fix: correct the default sku' }
                    )
                    Expected = @{
                        Status  = 'blocked'
                        Actions = @(@{ Type = 'FlagPullRequest'; PullRequest = 143; Flag = 'missing-label'; Blocking = $true })
                        Summary = @{
                            TriggeringPullRequests = @(141, 142, 143)
                            FirstTriggerAt         = '2026-09-01T10:00:00Z'
                            LastTriggerAt          = '2026-09-01T10:20:00Z'
                            DueAt                  = '2026-09-02T10:20:00Z'
                            Version                = $null
                            BlockingIssues         = @(@{ Code = 'missing-label'; PullRequest = 143 })
                        }
                        State   = @{
                            'pending.pullRequests[0].kind'              = 'Human'
                            'pending.pullRequests[0].moduleCodeChanged' = $false
                            'pending.pullRequests[0].formattingOnly'    = $false
                            'pending.pullRequests[0].triggersRelease'   = $true
                            'pending.pullRequests[1].moduleCodeChanged' = $true
                            'pending.pullRequests[1].formattingOnly'    = $true
                            'pending.pullRequests[1].triggersRelease'   = $true
                            'pending.pullRequests[2].triggersRelease'   = $true
                            'pending.pullRequests[2].versionLabels#'    = 0
                        }
                    }
                }
            )
        }
        @{
            Id         = 'engine-34'
            Title      = 'An opted-in repo-sync pull request stays in the release after its label is removed'
            Design     = 'Which PRs trigger a release > Opting in a routine bot PR; Correcting version labels'
            Assumption = 'An accepted opt-in is not withdrawn by removing the label. The pull request keeps triggering and needs a version label again before publication.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 110; MergedAt = '2026-09-01T10:00:00Z'; Author = 'azure-verified-modules[bot]'; Title = 'chore: run avm pre-commit'; ChangedFiles = @(@{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $true }) })
                    Expected = @{
                        Status  = 'idle'
                        Changed = $true
                        Summary = @{ PendingPullRequests = @(110); 'TriggeringPullRequests#' = 0; 'Flags#' = 0 }
                        State   = @{ 'pending.pullRequests[0].formattingOnly' = $true; 'pending.pullRequests[0].flags#' = 0 }
                    }
                }
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Label    = @(@{ Id = 5001; PullRequest = 110; Label = 'minor'; Actor = 'dave'; At = '2026-09-01T11:00:00Z' })
                    Expected = @{
                        Status  = 'waiting'
                        Actions = @(@{ Type = 'AcceptOptIn'; PullRequest = 110; Actor = 'dave'; Message = 'Pull request #110 joins the pending release. The opt-in counts as a merge at 2026-09-01T11:00:00Z.' })
                        Summary = @{ Version = '0.9.0'; DueAt = '2026-09-02T11:00:00Z' }
                    }
                }
                @{
                    Now      = '2026-09-01T11:30:00Z'
                    Label    = @(@{ Id = 5002; PullRequest = 110; Label = 'minor'; Action = 'unlabeled'; Actor = 'alice'; At = '2026-09-01T11:30:00Z' })
                    Expected = @{
                        Status  = 'blocked'
                        Actions = @(@{ Type = 'FlagPullRequest'; PullRequest = 110; Flag = 'missing-label'; Blocking = $true })
                        Summary = @{ TriggeringPullRequests = @(110); Version = $null; DueAt = '2026-09-02T11:00:00Z' }
                        State   = @{
                            'pending.pullRequests[0].triggersRelease' = $true
                            'pending.pullRequests[0].triggeredBy'     = 'opt-in'
                            'pending.pullRequests[0].optIn.by'        = 'dave'
                            'pending.pullRequests[0].versionLabels#'  = 0
                        }
                    }
                }
                @{
                    Now      = '2026-09-02T11:00:00Z'
                    Expected = @{ Status = 'blocked'; Changed = $false; Actions = @(@{ Type = 'BlockPublication'; Trigger = 'timer'; Issues = @(@{ Code = 'missing-label'; PullRequest = 110 }) }) }
                }
            )
        }
        @{
            Id         = 'engine-35'
            Title      = 'A #Release posted at the same time as a merge includes that merge'
            Design     = 'Commands > #Release; Release timing > Cutoff'
            Assumption = 'At equal timestamps the engine applies merges before label events and label events before comments.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:00:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Comment  = @(@{ Id = 7001; CreatedAt = '2026-09-01T10:00:00Z'; Author = 'alice'; Body = '#Release' })
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7001; Command = 'Release'; Accepted = $true; Message = 'Release requested. Publication starts now.' }
                            @{ Type = 'StartPublication'; Version = '0.8.3'; Trigger = 'release-command'; Record = @{ requestedBy = 'alice'; pullRequests = @(@{ number = 101 }) } }
                        )
                    }
                }
            )
        }
        @{
            Id         = 'engine-36'
            Title      = 'Commands apply in posted order, not in the order they are supplied, and each applies once'
            Design     = 'Commands'
            Steps      = @(
                @{
                    Now      = '2026-09-01T11:00:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Comment  = @(
                        @{ Id = 7002; CreatedAt = '2026-09-01T10:50:00Z'; Author = 'alice'; Body = '#Release' }
                        @{ Id = 7001; CreatedAt = '2026-09-01T10:30:00Z'; Author = 'dave'; Body = '#DoNotRelease checking the provider' }
                    )
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7001; Command = 'DoNotRelease'; Accepted = $true }
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7002; Command = 'Release'; Accepted = $true; Message = 'The hold is cleared. Release requested. Publication starts now.' }
                            @{ Type = 'StartPublication'; Version = '0.8.3'; Trigger = 'release-command'; Record = @{ requestedBy = 'alice' } }
                        )
                        State   = @{ hold = $null; 'commentCursor.id' = 7002; 'commentCursor.createdAt' = '2026-09-01T10:50:00Z' }
                    }
                }
                @{
                    Now      = '2026-09-01T11:30:00Z'
                    Expected = @{ Status = 'publishing'; Changed = $false }
                }
            )
        }
        @{
            Id         = 'engine-37'
            Title      = 'Non-events leave the timers alone'
            Design     = 'Release timing > Recommended policy; Which PRs trigger a release'
            Assumption = 'Non-triggering bot merges, notes edits, and non-version labels change neither timer.'
            Steps      = @(
                @{
                    Now      = '2026-09-01T10:30:00Z'
                    Merge    = @(@{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') })
                    Expected = @{ Status = 'waiting'; Summary = @{ DueAt = '2026-09-02T10:00:00Z' } }
                }
                @{
                    Now      = '2026-09-01T16:00:00Z'
                    Merge    = @(
                        @{ Number = 120; MergedAt = '2026-09-01T15:00:00Z'; Author = 'dependabot[bot]'; Title = 'chore(deps): bump actions/checkout'; ChangedFiles = @(@{ Path = '.github/workflows/test.yml'; Status = 'modified'; FormatEquivalent = $false }) }
                        @{ Number = 110; MergedAt = '2026-09-01T15:10:00Z'; Author = 'azure-verified-modules[bot]'; Title = 'chore: run avm pre-commit' }
                    )
                    Comment  = @(@{ Id = 7001; CreatedAt = '2026-09-01T15:30:00Z'; Author = 'alice'; Body = '#ReleaseNotes This release fixes the example.' })
                    Label    = @(@{ Id = 5001; PullRequest = 101; Label = 'documentation'; Actor = 'alice'; At = '2026-09-01T15:40:00Z' })
                    Expected = @{
                        Status  = 'waiting'
                        Changed = $true
                        Actions = @(
                            @{ Type = 'AcknowledgeCommand'; CommentId = 7001; Command = 'ReleaseNotes'; Accepted = $true; Message = 'Release notes updated.' }
                            @{ Type = 'FlagPullRequest'; PullRequest = 110; Flag = 'automation-module-code'; Blocking = $false }
                        )
                        Summary = @{
                            PendingPullRequests    = @(101, 110, 120)
                            TriggeringPullRequests = @(101)
                            FirstTriggerAt         = '2026-09-01T10:00:00Z'
                            LastTriggerAt          = '2026-09-01T10:00:00Z'
                            DueAt                  = '2026-09-02T10:00:00Z'
                            Version                = '0.8.3'
                        }
                        State   = @{
                            'pending.notes.commentary.text'         = 'This release fixes the example.'
                            'pending.pullRequests[0].versionLabels' = @('patch')
                            'labelCursor.id'                        = 5001
                        }
                    }
                }
            )
        }
        @{
            Id         = 'engine-38'
            Title      = 'An opt-in restarts the 24-hour timer but not the 72-hour cap'
            Design     = 'Release timing > Recommended policy; Which PRs trigger a release > Opting in a routine bot PR'
            Steps      = @(
                @{
                    Now      = '2026-09-01T12:30:00Z'
                    Merge    = @(
                        @{ Number = 101; MergedAt = '2026-09-01T10:00:00Z'; Labels = @('patch') }
                        @{ Number = 110; MergedAt = '2026-09-01T12:00:00Z'; Author = 'azure-verified-modules[bot]'; Title = 'chore: run avm pre-commit'; ChangedFiles = @(@{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $true }) }
                    )
                    Expected = @{ Status = 'waiting'; Summary = @{ TriggeringPullRequests = @(101); DueAt = '2026-09-02T10:00:00Z' } }
                }
                @{
                    Now      = '2026-09-02T08:00:00Z'
                    Label    = @(@{ Id = 5001; PullRequest = 110; Label = 'minor'; Actor = 'dave'; At = '2026-09-02T08:00:00Z' })
                    Expected = @{
                        Status  = 'waiting'
                        Actions = @(@{ Type = 'AcceptOptIn'; PullRequest = 110; Message = 'Pull request #110 joins the pending release. The opt-in counts as a merge at 2026-09-02T08:00:00Z.' })
                        Summary = @{
                            TriggeringPullRequests = @(101, 110)
                            FirstTriggerAt         = '2026-09-01T10:00:00Z'
                            LastTriggerAt          = '2026-09-02T08:00:00Z'
                            RestartDeadline        = '2026-09-03T08:00:00Z'
                            CapDeadline            = '2026-09-04T10:00:00Z'
                            DueAt                  = '2026-09-03T08:00:00Z'
                            Version                = '0.9.0'
                        }
                    }
                }
                @{
                    Now      = '2026-09-02T10:00:00Z'
                    Expected = @{ Status = 'waiting'; Changed = $false }
                }
                @{
                    Now      = '2026-09-03T08:00:00Z'
                    Expected = @{
                        Status  = 'publishing'
                        Actions = @(@{ Type = 'StartPublication'; Version = '0.9.0'; Trigger = 'timer'; Record = @{ pullRequests = @(@{ number = 101; triggersRelease = $true }, @{ number = 110; triggersRelease = $true; versionLabel = 'minor' }) } })
                    }
                }
            )
        }
    )
}
