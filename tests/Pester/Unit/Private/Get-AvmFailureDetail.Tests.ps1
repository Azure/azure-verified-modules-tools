#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmFailureDetail' {
    It 'headlines the positional diagnostic ahead of a bare status issue' {
        $detail = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Issues = @(
                    [pscustomobject]@{
                        Severity = 'error'
                        File     = 'tests/integration/deploy.tftest.hcl'
                        Line     = 0
                        Column   = 0
                        Message  = "test run 'apply' fail"
                    },
                    [pscustomobject]@{
                        Severity = 'error'
                        File     = 'tests/integration/deploy.tftest.hcl'
                        Line     = 17
                        Column   = 21
                        Message  = 'Test assertion failed - condition was false'
                    }
                )
            }
            Get-AvmFailureDetail -Result $result
        }
        $detail | Should -Match 'deploy\.tftest\.hcl:17:21'
        $detail | Should -Match 'Test assertion failed'
        $detail | Should -Not -Match "test run 'apply' fail"
    }

    It 'falls back to the first issue when none carry a position' {
        $detail = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Issues = @(
                    [pscustomobject]@{ Severity = 'error'; Message = 'first problem' },
                    [pscustomobject]@{ Severity = 'error'; Message = 'second problem' }
                )
            }
            Get-AvmFailureDetail -Result $result
        }
        $detail | Should -Match 'first problem'
    }

    It 'headlines the positional diagnostic from a failing chain step' {
        $detail = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Steps  = @(
                    [pscustomobject]@{ Step = 'lint'; Status = 'pass'; Result = $null },
                    [pscustomobject]@{
                        Step   = 'test'
                        Status = 'fail'
                        Result = [pscustomobject]@{
                            Issues = @(
                                [pscustomobject]@{ Severity = 'error'; Line = 0; Message = "test run 'apply' fail" },
                                [pscustomobject]@{ Severity = 'error'; File = 'main.tf'; Line = 4; Column = 2; Message = 'Unsupported argument' }
                            )
                        }
                    }
                )
            }
            Get-AvmFailureDetail -Result $result
        }
        $detail | Should -Match "Step 'test'"
        $detail | Should -Match 'main\.tf:4:2'
        $detail | Should -Match 'Unsupported argument'
    }

    It 'returns an empty string when there is nothing to report' {
        $detail = InModuleScope 'Avm.Authoring' {
            Get-AvmFailureDetail -Result ([pscustomobject]@{ Status = 'fail' })
        }
        $detail | Should -BeExactly ''
    }

    It 'F58: a later step naming a line beats an earlier one naming only a file' {
        # The ordinary PR shape: one stray space fails format, and a broken
        # test fails later carrying the only line number in the run.
        $detail = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Steps  = @(
                    [pscustomobject]@{
                        Step   = 'format'
                        Status = 'fail'
                        Result = [pscustomobject]@{
                            Issues = @(
                                [pscustomobject]@{
                                    Severity = 'error'
                                    File     = 'tests/unit/defaults.tftest.hcl'
                                    Message  = 'file is not formatted'
                                }
                            )
                        }
                    },
                    [pscustomobject]@{
                        Step   = 'unit test'
                        Status = 'fail'
                        Result = [pscustomobject]@{
                            Issues = @(
                                [pscustomobject]@{
                                    Severity = 'error'
                                    File     = 'tests/unit/defaults.tftest.hcl'
                                    Line     = 17
                                    Column   = 21
                                    Message  = 'Test assertion failed'
                                }
                            )
                        }
                    }
                )
            }
            Get-AvmFailureDetail -Result $result
        }
        $detail | Should -Match "Step 'unit test'"
        $detail | Should -Match 'defaults\.tftest\.hcl:17:21'
        $detail | Should -Not -Match "Step 'format'"
    }

    It 'F58: keeps the first failing step when every failure is equally precise' {
        $detail = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Steps  = @(
                    [pscustomobject]@{ Step = 'sync'; Status = 'error'; Error = 'tool missing'; Result = $null },
                    [pscustomobject]@{ Step = 'docs'; Status = 'error'; Error = 'also broken'; Result = $null }
                )
            }
            Get-AvmFailureDetail -Result $result
        }
        $detail | Should -Match "Step 'sync'"
        $detail | Should -Match 'tool missing'
    }

    It 'F58: a later error beats an earlier positioned nit from another step' {
        # The measured shape: format drift, lint nits and broken tests in one
        # run. lint reports first and carries a line, so step order alone hands
        # the single annotation to a style nit and hides twelve real errors.
        $detail = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Steps  = @(
                    [pscustomobject]@{
                        Step   = 'lint'
                        Status = 'fail'
                        Result = [pscustomobject]@{
                            Issues = @([pscustomobject]@{ Severity = 'info'; File = 'main.tf'; Line = 1; Column = 1; Message = 'variables in the same file' })
                        }
                    },
                    [pscustomobject]@{
                        Step   = 'unit test'
                        Status = 'fail'
                        Result = [pscustomobject]@{
                            Issues = @([pscustomobject]@{ Severity = 'error'; File = 'tests/unit/defaults.tftest.hcl'; Line = 17; Column = 17; Message = 'Test assertion failed' })
                        }
                    }
                )
            }
            Get-AvmFailureDetail -Result $result
        }
        $detail | Should -Match "Step 'unit test'"
        $detail | Should -Match 'Test assertion failed'
        $detail | Should -Not -Match "Step 'lint'"
    }
}

Describe 'Get-AvmStepRank' {
    It 'F58: ranks a file and line above a file alone, and a file above nothing' {
        # Asserts the ordering rather than the numbers: the weighting is an
        # implementation detail, the precedence is the contract.
        $ranks = InModuleScope 'Avm.Authoring' {
            $positioned = [pscustomobject]@{
                Step   = 'unit test'
                Status = 'fail'
                Result = [pscustomobject]@{
                    Issues = @([pscustomobject]@{ Severity = 'error'; File = 'a.tf'; Line = 9; Column = 3; Message = 'boom' })
                }
            }
            $fileOnly = [pscustomobject]@{
                Step   = 'format'
                Status = 'fail'
                Result = [pscustomobject]@{
                    Issues = @([pscustomobject]@{ Severity = 'error'; File = 'a.tf'; Message = 'not formatted' })
                }
            }
            $bare = [pscustomobject]@{ Step = 'sync'; Status = 'error'; Error = 'tool missing'; Result = $null }
            [pscustomobject]@{
                Positioned = Get-AvmStepRank -Step $positioned
                FileOnly   = Get-AvmStepRank -Step $fileOnly
                Bare       = Get-AvmStepRank -Step $bare
            }
        }
        $ranks.Positioned | Should -BeGreaterThan $ranks.FileOnly
        $ranks.FileOnly | Should -BeGreaterThan $ranks.Bare
    }

    It 'F58: ranks severity above precision, so an error outranks a positioned nit' {
        # The judgement this encodes: a developer given one annotation wants the
        # error, even when a lower-severity finding points at an exact line.
        $ranks = InModuleScope 'Avm.Authoring' {
            $positionedNit = [pscustomobject]@{
                Step   = 'lint'
                Status = 'fail'
                Result = [pscustomobject]@{
                    Issues = @([pscustomobject]@{ Severity = 'info'; File = 'main.tf'; Line = 1; Column = 1; Message = 'nit' })
                }
            }
            $unpositionedError = [pscustomobject]@{
                Step   = 'docs'
                Status = 'fail'
                Result = [pscustomobject]@{
                    Issues = @([pscustomobject]@{ Severity = 'error'; File = 'README.md'; Message = 'out of date' })
                }
            }
            [pscustomobject]@{
                Nit   = Get-AvmStepRank -Step $positionedNit
                Error = Get-AvmStepRank -Step $unpositionedError
            }
        }
        $ranks.Error | Should -BeGreaterThan $ranks.Nit
    }
}

Describe 'Get-AvmSeverityWeight' {
    It 'F58: orders error above warning above info, case-insensitively' {
        $weights = InModuleScope 'Avm.Authoring' {
            [pscustomobject]@{
                Error   = Get-AvmSeverityWeight -Severity 'ERROR'
                Warning = Get-AvmSeverityWeight -Severity 'Warning'
                Info    = Get-AvmSeverityWeight -Severity 'info'
                Notice  = Get-AvmSeverityWeight -Severity 'notice'
            }
        }
        $weights.Error | Should -BeGreaterThan $weights.Warning
        $weights.Warning | Should -BeGreaterThan $weights.Info
        # tflint says 'notice' where the renderer says 'info'; same tier.
        $weights.Notice | Should -Be $weights.Info
    }

    It 'F58: scores an unknown or absent severity between error and info' {
        $weights = InModuleScope 'Avm.Authoring' {
            [pscustomobject]@{
                Error   = Get-AvmSeverityWeight -Severity 'error'
                Unknown = Get-AvmSeverityWeight -Severity 'catastrophe'
                Absent  = Get-AvmSeverityWeight -Severity $null
                Info    = Get-AvmSeverityWeight -Severity 'info'
            }
        }
        # A new severity name must not be able to outrank a real error, nor be
        # buried beneath a nit.
        $weights.Unknown | Should -BeLessThan $weights.Error
        $weights.Unknown | Should -BeGreaterThan $weights.Info
        $weights.Absent | Should -Be $weights.Unknown
    }
}

Describe 'Get-AvmPrimaryIssue severity' {
    It 'F58: breaks a positional tie on severity, so a nit is not named as the cause' {
        # tflint reports the info nits and the warning that actually failed the
        # step, all with a line. Taking the first states a cause that is not the
        # cause: an info finding alone would not have failed lint.
        $issue = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Issues = @(
                    [pscustomobject]@{ Severity = 'info'; File = 'main.tf'; Line = 1; Column = 1; Message = 'variables in the same file' },
                    [pscustomobject]@{ Severity = 'info'; File = 'main.tf'; Line = 93; Column = 1; Message = 'no description' },
                    [pscustomobject]@{ Severity = 'warning'; File = 'main.tf'; Line = 93; Column = 1; Message = 'declared but not used' }
                )
            }
            Get-AvmPrimaryIssue -Result $result
        }
        $issue.Severity | Should -Be 'warning'
        $issue.Message | Should -Be 'declared but not used'
    }

    It 'F24b: keeps position dominant over severity within a step' {
        # The bare status issue restates the failure beneath it, so it must lose
        # even when it is scored the more severe of the two. This is the
        # opposite precedence to Get-AvmStepRank, and deliberately so.
        $issue = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Issues = @(
                    [pscustomobject]@{ Severity = 'error'; File = 'a.tftest.hcl'; Message = "test run 'apply' fail" },
                    [pscustomobject]@{ Severity = 'info'; File = 'a.tftest.hcl'; Line = 12; Column = 5; Message = 'the real diagnostic' }
                )
            }
            Get-AvmPrimaryIssue -Result $result
        }
        $issue.Message | Should -Be 'the real diagnostic'
        $issue.Line | Should -Be 12
    }
}

Describe 'Get-AvmFailurePosition' {
    It 'F41: reports the position of the issue the detail headlines' {
        $position = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Issues = @(
                    [pscustomobject]@{ Severity = 'error'; File = 'tests/unit/a.tftest.hcl'; Line = 0; Column = 0; Message = "test run 'x' fail" },
                    [pscustomobject]@{ Severity = 'error'; File = 'tests/unit/a.tftest.hcl'; Line = 17; Column = 21; Message = 'Test assertion failed' }
                )
            }
            Get-AvmFailurePosition -Result $result
        }
        $position.File | Should -BeExactly 'tests/unit/a.tftest.hcl'
        $position.Line | Should -Be 17
        $position.Column | Should -Be 21
    }

    It 'F41: reaches into a failing chain step' {
        $position = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Steps  = @(
                    [pscustomobject]@{ Step = 'lint'; Status = 'pass'; Result = $null },
                    [pscustomobject]@{
                        Step   = 'unit test'
                        Status = 'fail'
                        Result = [pscustomobject]@{
                            Issues = @(
                                [pscustomobject]@{ Severity = 'error'; File = 'main.tf'; Line = 4; Column = 2; Message = 'Unsupported argument' }
                            )
                        }
                    }
                )
            }
            Get-AvmFailurePosition -Result $result
        }
        $position.File | Should -BeExactly 'main.tf'
        $position.Line | Should -Be 4
    }

    It 'F41: returns null when the step reports a bare error string' {
        $position = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'error'
                Steps  = @(
                    [pscustomobject]@{ Step = 'sync'; Status = 'error'; Error = 'tool missing'; Result = $null }
                )
            }
            Get-AvmFailurePosition -Result $result
        }
        $position | Should -BeNullOrEmpty
    }

    It 'F41: returns null when no issue carries a file' {
        $position = InModuleScope 'Avm.Authoring' {
            Get-AvmFailurePosition -Result ([pscustomobject]@{
                    Status = 'fail'
                    Issues = @([pscustomobject]@{ Severity = 'error'; Message = 'no position' })
                })
        }
        $position | Should -BeNullOrEmpty
    }

    It 'F58: anchors on the same step the detail headlines' {
        $observed = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Steps  = @(
                    [pscustomobject]@{
                        Step   = 'format'
                        Status = 'fail'
                        Result = [pscustomobject]@{
                            Issues = @(
                                [pscustomobject]@{ Severity = 'error'; File = 'tests/unit/defaults.tftest.hcl'; Message = 'not formatted' }
                            )
                        }
                    },
                    [pscustomobject]@{
                        Step   = 'unit test'
                        Status = 'fail'
                        Result = [pscustomobject]@{
                            Issues = @(
                                [pscustomobject]@{ Severity = 'error'; File = 'tests/unit/defaults.tftest.hcl'; Line = 17; Column = 21; Message = 'Test assertion failed' }
                            )
                        }
                    }
                )
            }
            [pscustomobject]@{
                Detail   = Get-AvmFailureDetail -Result $result
                Position = Get-AvmFailurePosition -Result $result
            }
        }
        $observed.Position.Line | Should -Be 17
        $observed.Position.Column | Should -Be 21
        $observed.Detail | Should -Match "Step 'unit test'"
    }
}