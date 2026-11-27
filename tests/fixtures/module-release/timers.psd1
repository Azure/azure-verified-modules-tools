@{
    Area      = 'timers'
    Function  = 'Get-AvmReleaseDeadline'
    Scenarios = @(
        @{
            Id       = 'timers-01'
            Title    = 'A single Monday merge is due 24 hours later'
            Design   = 'Release timing: 24 hours after the latest release-triggering merge'
            Input    = @{
                TriggerTimes = @('2026-09-07T09:00:00Z')
            }
            Expected = @{
                FirstTriggerAt  = '2026-09-07T09:00:00Z'
                LastTriggerAt   = '2026-09-07T09:00:00Z'
                RestartDeadline = '2026-09-08T09:00:00Z'
                CapDeadline     = '2026-09-10T09:00:00Z'
                DueAt           = '2026-09-08T09:00:00Z'
                DueBy           = 'timer'
            }
        }
        @{
            Id       = 'timers-02'
            Title    = 'A Friday afternoon merge moves past the weekend to Monday'
            Design   = 'Release timing: a timer that ends on Saturday or Sunday UTC gets 48 more hours'
            Input    = @{
                TriggerTimes = @('2026-09-04T15:00:00Z')
            }
            Expected = @{
                RestartDeadline = '2026-09-07T15:00:00Z'
                CapDeadline     = '2026-09-07T15:00:00Z'
                DueAt           = '2026-09-07T15:00:00Z'
                DueBy           = 'timer'
            }
        }
        @{
            Id       = 'timers-03'
            Title    = 'A Sunday night merge ends on Monday and gets no extension'
            Design   = 'Release timing: only a timer ending on Saturday or Sunday is extended'
            Input    = @{
                TriggerTimes = @('2026-09-06T23:50:00Z')
            }
            Expected = @{
                RestartDeadline = '2026-09-07T23:50:00Z'
                CapDeadline     = '2026-09-09T23:50:00Z'
                DueAt           = '2026-09-07T23:50:00Z'
                DueBy           = 'timer'
            }
        }
        @{
            Id       = 'timers-04'
            Title    = 'A second merge restarts the 24-hour timer'
            Design   = 'Release timing: each release-triggering merge restarts the 24-hour timer'
            Input    = @{
                TriggerTimes = @('2026-09-07T09:00:00Z', '2026-09-07T20:00:00Z')
            }
            Expected = @{
                FirstTriggerAt  = '2026-09-07T09:00:00Z'
                LastTriggerAt   = '2026-09-07T20:00:00Z'
                RestartDeadline = '2026-09-08T20:00:00Z'
                CapDeadline     = '2026-09-10T09:00:00Z'
                DueAt           = '2026-09-08T20:00:00Z'
                DueBy           = 'timer'
            }
        }
        @{
            Id       = 'timers-05'
            Title    = 'The 72-hour cap wins when merges keep restarting the timer'
            Design   = 'Release timing: the 72-hour cap starts at the first merge and never restarts'
            Input    = @{
                TriggerTimes = @('2026-09-07T09:00:00Z', '2026-09-08T08:00:00Z', '2026-09-09T12:00:00Z')
            }
            Expected = @{
                RestartDeadline = '2026-09-10T12:00:00Z'
                CapDeadline     = '2026-09-10T09:00:00Z'
                DueAt           = '2026-09-10T09:00:00Z'
                DueBy           = 'cap'
            }
        }
        @{
            Id       = 'timers-06'
            Title    = 'Both timers ending on Saturday move to Monday and the cap still wins'
            Design   = 'Release timing: the weekend rule applies to the 24-hour timer and the 72-hour cap'
            Input    = @{
                TriggerTimes = @('2026-09-02T10:00:00Z', '2026-09-03T09:00:00Z', '2026-09-04T11:00:00Z')
            }
            Expected = @{
                RestartDeadline = '2026-09-07T11:00:00Z'
                CapDeadline     = '2026-09-07T10:00:00Z'
                DueAt           = '2026-09-07T10:00:00Z'
                DueBy           = 'cap'
            }
        }
        @{
            Id         = 'timers-07'
            Title      = 'The weekend check uses the UTC end day, not the local day of the input'
            Design     = 'Release timing: Saturday or Sunday (UTC)'
            Assumption = 'Input offsets are converted to UTC before the weekend check. A Thursday 22:00 merge at UTC-5 is Friday 03:00 UTC, so its timer ends on Saturday UTC and moves to Monday.'
            Input      = @{
                TriggerTimes = @('2026-09-03T22:00:00-05:00')
            }
            Expected   = @{
                FirstTriggerAt  = '2026-09-04T03:00:00Z'
                RestartDeadline = '2026-09-07T03:00:00Z'
                CapDeadline     = '2026-09-07T03:00:00Z'
                DueAt           = '2026-09-07T03:00:00Z'
                DueBy           = 'timer'
            }
        }
        @{
            Id       = 'timers-08'
            Title    = 'Trigger times in any order give the same deadlines'
            Design   = 'Release timing'
            Input    = @{
                TriggerTimes = @('2026-09-07T20:00:00Z', '2026-09-07T09:00:00Z')
            }
            Expected = @{
                FirstTriggerAt  = '2026-09-07T09:00:00Z'
                LastTriggerAt   = '2026-09-07T20:00:00Z'
                RestartDeadline = '2026-09-08T20:00:00Z'
                CapDeadline     = '2026-09-10T09:00:00Z'
                DueBy           = 'timer'
            }
        }
        @{
            Id         = 'timers-09'
            Title      = 'A timer ending exactly at Saturday 00:00 UTC is extended'
            Design     = 'Release timing: Saturday or Sunday (UTC)'
            Assumption = 'Saturday starts at 00:00:00 UTC, so a timer ending at that instant counts as ending on Saturday.'
            Input      = @{
                TriggerTimes = @('2026-09-04T00:00:00Z')
            }
            Expected   = @{
                RestartDeadline = '2026-09-07T00:00:00Z'
                CapDeadline     = '2026-09-07T00:00:00Z'
                DueAt           = '2026-09-07T00:00:00Z'
                DueBy           = 'timer'
            }
        }
        @{
            Id       = 'timers-10'
            Title    = 'A timer ending one second before Saturday is not extended'
            Design   = 'Release timing: Saturday or Sunday (UTC)'
            Input    = @{
                TriggerTimes = @('2026-09-03T23:59:59Z')
            }
            Expected = @{
                RestartDeadline = '2026-09-04T23:59:59Z'
                CapDeadline     = '2026-09-08T23:59:59Z'
                DueAt           = '2026-09-04T23:59:59Z'
                DueBy           = 'timer'
            }
        }
        @{
            Id         = 'timers-11'
            Title      = 'A Saturday merge ending on Sunday moves to Tuesday'
            Design     = 'Release timing: a timer that ends on Saturday or Sunday UTC gets 48 more hours'
            Assumption = 'The extension applies once and is always 48 hours, so a Sunday end moves to Tuesday rather than Monday.'
            Input      = @{
                TriggerTimes = @('2026-09-05T10:00:00Z')
            }
            Expected   = @{
                RestartDeadline = '2026-09-08T10:00:00Z'
                CapDeadline     = '2026-09-08T10:00:00Z'
                DueAt           = '2026-09-08T10:00:00Z'
                DueBy           = 'timer'
            }
        }
        @{
            Id       = 'timers-12'
            Title    = 'A cap ending on Friday stops a Friday merge from waiting for the weekend'
            Design   = 'Release timing: the release goes out at whichever timer ends first'
            Input    = @{
                TriggerTimes = @('2026-09-01T20:00:00Z', '2026-09-04T08:00:00Z')
            }
            Expected = @{
                RestartDeadline = '2026-09-07T08:00:00Z'
                CapDeadline     = '2026-09-04T20:00:00Z'
                DueAt           = '2026-09-04T20:00:00Z'
                DueBy           = 'cap'
            }
        }
        @{
            Id         = 'timers-13'
            Title      = 'A weekend-extended cap can end after a later unextended timer'
            Design     = 'Release timing: each timer gets the weekend extension separately'
            Assumption = 'The weekend rule extends each timer on its own. The cap does not stay at its unextended weekend end.'
            Input      = @{
                TriggerTimes = @('2026-09-02T12:00:00Z', '2026-09-04T06:00:00Z')
            }
            Expected   = @{
                RestartDeadline = '2026-09-07T06:00:00Z'
                CapDeadline     = '2026-09-07T12:00:00Z'
                DueAt           = '2026-09-07T06:00:00Z'
                DueBy           = 'timer'
            }
        }
        @{
            Id       = 'timers-14'
            Title    = 'No trigger times is an error'
            Design   = 'Release timing'
            Input    = @{
                TriggerTimes = @()
            }
            Throws   = 'At least one trigger time is required'
        }
        @{
            Id       = 'timers-15'
            Title    = 'A timestamp without an offset is an error'
            Design   = 'Release timing: times are UTC'
            Input    = @{
                TriggerTimes = @('2026-09-07 09:00')
            }
            Throws   = 'must be an ISO-8601 timestamp with an offset'
        }
    )
}
