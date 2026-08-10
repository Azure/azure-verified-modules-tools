#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    $script:savedActions = $env:GITHUB_ACTIONS
    $script:savedRunner = $env:RUNNER_DEBUG
    $script:savedVerbose = $env:AVM_VERBOSE
    $script:savedNoColor = $env:NO_COLOR
    $script:savedColorForce = $env:CLICOLOR_FORCE
}

AfterAll {
    $env:GITHUB_ACTIONS = $script:savedActions
    $env:RUNNER_DEBUG = $script:savedRunner
    $env:AVM_VERBOSE = $script:savedVerbose
    $env:NO_COLOR = $script:savedNoColor
    $env:CLICOLOR_FORCE = $script:savedColorForce
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Write-AvmLog' {
    BeforeEach {
        $env:GITHUB_ACTIONS = ''
        $env:RUNNER_DEBUG = ''
        $env:AVM_VERBOSE = ''
        Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue
        Remove-Item Env:\CLICOLOR_FORCE -ErrorAction SilentlyContinue
    }

    Context 'outside GitHub Actions' {
        It 'writes Info to the information stream' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'plain info' -Level Info -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }

            @($messages) | Should -Contain 'plain info'
        }

        It 'uses semantic colours when forced and honours NO_COLOR' {
            $observed = InModuleScope 'Avm.Authoring' {
                $escape = [char]27
                $env:CLICOLOR_FORCE = '1'
                $coloured = Format-AvmLogText -Text 'passed' -Level Pass
                $env:NO_COLOR = '1'
                $plain = Format-AvmLogText -Text 'passed' -Level Pass
                [pscustomobject]@{
                    Coloured = $coloured
                    Plain    = $plain
                    Escape   = [string]$escape
                }
            }
            $observed.Coloured | Should -Be "$($observed.Escape)[32mpassed$($observed.Escape)[0m"
            $observed.Plain | Should -Be 'passed'
        }

        It 'forces semantic colours for any non-zero CLICOLOR_FORCE value' {
            $observed = InModuleScope 'Avm.Authoring' {
                $escape = [char]27
                $env:CLICOLOR_FORCE = '2'
                Format-AvmLogText -Text 'passed' -Level Pass
            }
            $escape = [char]27
            $observed | Should -Be "$escape[32mpassed$escape[0m"
        }

        It 'does not force semantic colours for CLICOLOR_FORCE=0' {
            $observed = InModuleScope 'Avm.Authoring' {
                $env:CLICOLOR_FORCE = '0'
                Test-AvmColorEnabled
            }
            if ([Console]::IsOutputRedirected -or [Console]::IsErrorRedirected) {
                $observed | Should -BeFalse
            }
        }

        It 'writes Warning to the warning stream, not the information stream' {
            $observed = InModuleScope 'Avm.Authoring' {
                $info = @()
                $warn = @()
                Write-AvmLog 'careful' -Level Warning -InformationVariable info -WarningVariable warn
                [pscustomobject]@{
                    Info    = @($info | ForEach-Object { [string]$_.MessageData })
                    Warning = @($warn | ForEach-Object { [string]$_ })
                }
            }
            @($observed.Warning) | Should -Contain 'careful'
            @($observed.Info) | Should -Not -Contain 'careful'
        }

        It 'writes Error to the information stream so it is never swallowed' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'boom' -Level Error -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain 'boom'
        }

        It 'suppresses Verbose when verbose is not enabled' {
            # F47: this must read the verbose stream. Verbose output never reaches
            # -InformationVariable, so capturing that stream made the assertion
            # unfailable regardless of what Write-AvmLog did.
            $messages = InModuleScope 'Avm.Authoring' {
                @(Write-AvmLog 'chatty' -Level Verbose 4>&1 | ForEach-Object { [string]$_ })
            }
            @($messages) | Should -Not -Contain 'chatty'
        }

        It 'emits Verbose to the verbose stream when verbose is enabled' {
            # The positive control for the test above: without it, a Write-AvmLog
            # that dropped every Verbose message unconditionally would still pass.
            $env:AVM_VERBOSE = '1'
            $messages = InModuleScope 'Avm.Authoring' {
                @(Write-AvmLog 'chatty' -Level Verbose 4>&1 | ForEach-Object { [string]$_ })
            }
            @($messages) | Should -Contain 'chatty'
        }
    }

    Context 'inside GitHub Actions' {
        BeforeEach {
            $env:GITHUB_ACTIONS = 'true'
        }

        It 'emits workflow command annotations for warning and error' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'be careful' -Level Warning -InformationVariable captured
                Write-AvmLog 'it broke' -Level Error -InformationVariable +captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain '::warning::be careful'
            @($messages) | Should -Contain '::error::it broke'
        }

        It 'downgrades Verbose to ::debug:: when verbose is off' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'trace me' -Level Verbose -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain '::debug::trace me'
        }

        It 'escapes newlines in annotations' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog "line one`nline two" -Level Error -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain '::error::line one%0Aline two'
        }

        It 'emits group markers' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Enter-AvmLogGroup -Name 'a group' -InformationVariable captured
                Exit-AvmLogGroup -InformationVariable +captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain '::group::a group'
            @($messages) | Should -Contain '::endgroup::'
        }

        It 'F41: strips leading indentation from the annotation payload' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog '    run something -> fail' -Level Error -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain '::error::run something -> fail'
        }

        It 'F41: anchors the annotation on file, line and column' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'assertion failed' -Level Error -File 'tests/unit/a.tftest.hcl' -Line 17 -Column 21 -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain '::error file=tests/unit/a.tftest.hcl,line=17,col=21::assertion failed'
        }

        It 'F41: normalises Windows separators so GitHub can match the diff' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'assertion failed' -Level Error -File 'tests\unit\a.tftest.hcl' -Line 4 -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain '::error file=tests/unit/a.tftest.hcl,line=4::assertion failed'
        }

        It 'F41: rebases an absolute path onto the workspace root' {
            $messages = InModuleScope 'Avm.Authoring' {
                $saved = $env:GITHUB_WORKSPACE
                try {
                    $env:GITHUB_WORKSPACE = 'C:\work\repo'
                    $captured = @()
                    Write-AvmLog 'boom' -Level Error -File 'C:\work\repo\tests\unit\a.tftest.hcl' -Line 2 -InformationVariable captured
                    @($captured | ForEach-Object { [string]$_.MessageData })
                }
                finally {
                    $env:GITHUB_WORKSPACE = $saved
                }
            }
            @($messages) | Should -Contain '::error file=tests/unit/a.tftest.hcl,line=2::boom'
        }

        It 'F41: falls back to an unanchored annotation when there is no position' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'no position here' -Level Error -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain '::error::no position here'
        }

        It 'F41: omits col when line is unknown' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'file only' -Level Error -File 'main.tf' -Column 9 -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain '::error file=main.tf::file only'
        }
    }

    Context 'group markers outside GitHub Actions' {
        It 'emits nothing' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Enter-AvmLogGroup -Name 'a group' -InformationVariable captured
                Exit-AvmLogGroup -InformationVariable +captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages).Count | Should -Be 0
        }
    }
}

Describe 'Test-AvmDebugMode' {
    BeforeEach {
        $env:GITHUB_ACTIONS = ''
        $env:RUNNER_DEBUG = ''
        $env:AVM_VERBOSE = ''
    }

    It 'is false when neither RUNNER_DEBUG nor AVM_VERBOSE is set' {
        InModuleScope 'Avm.Authoring' { Test-AvmDebugMode } | Should -BeFalse
    }

    It 'is true when GitHub Actions debug logging is enabled' {
        $env:RUNNER_DEBUG = '1'
        InModuleScope 'Avm.Authoring' { Test-AvmDebugMode } | Should -BeTrue
    }

    It 'is true when AVM_VERBOSE is set' {
        $env:AVM_VERBOSE = 'true'
        InModuleScope 'Avm.Authoring' { Test-AvmDebugMode } | Should -BeTrue
    }

    It 'ignores values that are not truthy' {
        $env:RUNNER_DEBUG = '0'
        InModuleScope 'Avm.Authoring' { Test-AvmDebugMode } | Should -BeFalse
    }
}

Describe 'Format-AvmDuration' {
    BeforeEach {
        $env:GITHUB_ACTIONS = ''
        $env:RUNNER_DEBUG = ''
        $env:AVM_VERBOSE = ''
    }

    It 'renders sub-second durations in milliseconds' {
        InModuleScope 'Avm.Authoring' {
            Format-AvmDuration -Duration ([timespan]::FromMilliseconds(250))
        } | Should -Be '250 ms'
    }

    It 'renders seconds with one decimal place' {
        InModuleScope 'Avm.Authoring' {
            Format-AvmDuration -Duration ([timespan]::FromSeconds(4.25))
        } | Should -Be '4.3s'
    }

    It 'renders minutes and seconds' {
        InModuleScope 'Avm.Authoring' {
            Format-AvmDuration -Duration ([timespan]::FromSeconds(185))
        } | Should -Be '3m 05s'
    }
}

Describe 'Format-AvmTimestamp' {
    BeforeEach {
        $env:GITHUB_ACTIONS = ''
        $env:RUNNER_DEBUG = ''
        $env:AVM_VERBOSE = ''
    }

    It 'renders UTC time with a Z suffix' {
        $stamp = [datetime]::new(2026, 7, 31, 9, 8, 7, [System.DateTimeKind]::Utc)
        InModuleScope 'Avm.Authoring' -Parameters @{ T = $stamp } {
            param($T)
            Format-AvmTimestamp -Timestamp $T
        } | Should -Be '09:08:07Z'
    }
}

Describe 'Format-AvmTimingSuffix' {
    BeforeEach {
        $env:GITHUB_ACTIONS = ''
        $env:RUNNER_DEBUG = ''
        $env:AVM_VERBOSE = ''
    }

    It 'returns an empty string when there is no timing data' {
        $item = [pscustomobject]@{ Status = 'pass' }
        InModuleScope 'Avm.Authoring' -Parameters @{ I = $item } {
            param($I)
            Format-AvmTimingSuffix -InputObject $I
        } | Should -Be ''
    }

    It 'renders duration and the start/end window' {
        $start = [datetime]::new(2026, 7, 31, 9, 0, 0, [System.DateTimeKind]::Utc)
        $item = [pscustomobject]@{
            Status     = 'pass'
            DurationMs = 1500
            StartTime  = $start
            EndTime    = $start.AddSeconds(1.5)
        }
        $suffix = InModuleScope 'Avm.Authoring' -Parameters @{ I = $item } {
            param($I)
            Format-AvmTimingSuffix -InputObject $I
        }
        $suffix | Should -Be ' (1.5s; 09:00:00Z -> 09:00:01Z)'
    }
}
