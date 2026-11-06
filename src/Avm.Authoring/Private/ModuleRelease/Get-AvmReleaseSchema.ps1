function Get-AvmReleaseSchema {
    <#
    .SYNOPSIS
        Return the structural schema for release state or a release record.

    .DESCRIPTION
        Returns the schema that Test-AvmReleaseShape uses for schema version 1 of the release-state documents.

        - State describes state.json on the avm-release-state branch. It holds the pending release, the comment and label cursors, the hold, and the publication in progress.
        - Record describes an immutable releases/vX.Y.Z.json file, written once at the publication cutoff.

    .PARAMETER Kind
        The document kind: State or Record.

    .EXAMPLE
        Get-AvmReleaseSchema -Kind State

        Returns the state.json schema.

    .OUTPUTS
        Ordered dictionary schema node.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('State', 'Record')]
        [string] $Kind
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $label = 'enum:patch|minor|major'
    $kinds = 'enum:Human|RoutineBot|Automation'
    $triggers = 'enum:timer|cap|release-command'

    if ($Kind -eq 'Record') {
        return [ordered]@{
            Properties = [ordered]@{
                schemaVersion   = 'int'
                repository      = 'repo'
                version         = 'version'
                previousVersion = 'version'
                increment       = $label
                commit          = 'sha'
                cutoffAt        = 'timestamp'
                trigger         = $triggers
                requestedBy     = 'text?'
                notes           = 'text'
                pullRequests    = [ordered]@{
                    ArrayOf = [ordered]@{
                        Properties = [ordered]@{
                            number          = 'int'
                            title           = 'string'
                            author          = 'text'
                            kind            = $kinds
                            mergedAt        = 'timestamp'
                            mergeCommit     = 'sha'
                            triggersRelease = 'bool'
                            versionLabel    = 'enum?:patch|minor|major'
                            breaking        = 'bool'
                        }
                    }
                }
            }
        }
    }

    $pullRequest = [ordered]@{
        Properties = [ordered]@{
            number            = 'int'
            title             = 'string'
            author            = 'text'
            kind              = $kinds
            mergedAt          = 'timestamp'
            mergeCommit       = 'sha'
            triggersRelease   = 'bool'
            triggeredAt       = 'timestamp?'
            triggeredBy       = 'enum?:merge|opt-in'
            optIn             = [ordered]@{
                Nullable   = $true
                Properties = [ordered]@{
                    by = 'text'
                    at = 'timestamp'
                }
            }
            versionLabels     = [ordered]@{ ArrayOf = $label }
            labelChanges      = [ordered]@{
                ArrayOf = [ordered]@{
                    Properties = [ordered]@{
                        label  = $label
                        action = 'enum:labeled|unlabeled'
                        actor  = 'text'
                        at     = 'timestamp'
                    }
                }
            }
            breaking          = [ordered]@{
                Properties = [ordered]@{
                    declared        = 'bool'
                    whatChanges     = 'text?'
                    requiredUpgrade = 'text?'
                    issues          = [ordered]@{ ArrayOf = 'text' }
                }
            }
            moduleCodeChanged = 'bool'
            formattingOnly    = 'bool'
            flags             = [ordered]@{ ArrayOf = 'text' }
        }
    }

    return [ordered]@{
        Properties = [ordered]@{
            schemaVersion = 'int'
            repository    = 'repo'
            releaseIssue  = [ordered]@{
                Nullable   = $true
                Properties = [ordered]@{ number = 'int' }
            }
            commentCursor = [ordered]@{
                Nullable   = $true
                Properties = [ordered]@{
                    createdAt = 'timestamp'
                    id        = 'int'
                }
            }
            labelCursor   = [ordered]@{
                Nullable   = $true
                Properties = [ordered]@{
                    at = 'timestamp'
                    id = 'int'
                }
            }
            hold          = [ordered]@{
                Nullable   = $true
                Properties = [ordered]@{
                    reason    = 'text'
                    placedBy  = 'text'
                    placedAt  = 'timestamp'
                    since     = 'timestamp'
                    commentId = 'int'
                }
            }
            pending       = [ordered]@{
                Properties = [ordered]@{
                    pullRequests   = [ordered]@{ ArrayOf = $pullRequest }
                    releaseRequest = [ordered]@{
                        Nullable   = $true
                        Properties = [ordered]@{
                            requestedBy = 'text'
                            requestedAt = 'timestamp'
                            commentId   = 'int'
                        }
                    }
                    notes          = [ordered]@{
                        Properties = [ordered]@{
                            commentary       = [ordered]@{
                                Nullable   = $true
                                Properties = [ordered]@{
                                    text  = 'text'
                                    setBy = 'text'
                                    setAt = 'timestamp'
                                }
                            }
                            breakingOverride = [ordered]@{
                                Nullable   = $true
                                Properties = [ordered]@{
                                    text                = 'text'
                                    coveredPullRequests = [ordered]@{ ArrayOf = 'int' }
                                    setBy               = 'text'
                                    setAt               = 'timestamp'
                                }
                            }
                        }
                    }
                }
            }
            publication   = [ordered]@{
                Nullable   = $true
                Properties = [ordered]@{
                    version         = 'version'
                    previousVersion = 'version'
                    commit          = 'sha'
                    cutoffAt        = 'timestamp'
                    trigger         = $triggers
                    stage           = 'enum:cutoff'
                    pullRequests    = [ordered]@{
                        ArrayOf = [ordered]@{
                            Properties = [ordered]@{
                                number       = 'int'
                                versionLabel = 'enum?:patch|minor|major'
                            }
                        }
                    }
                }
            }
        }
    }
}
