#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    $script:savedActions = $env:GITHUB_ACTIONS
    $script:savedRunner = $env:RUNNER_DEBUG
    $script:savedVerbose = $env:AVM_VERBOSE
}

AfterAll {
    $env:GITHUB_ACTIONS = $script:savedActions
    $env:RUNNER_DEBUG = $script:savedRunner
    $env:AVM_VERBOSE = $script:savedVerbose
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Write-AvmLog' {
    BeforeEach {
        $env:GITHUB_ACTIONS = ''
        $env:RUNNER_DEBUG = ''
        $env:AVM_VERBOSE = ''
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
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'chatty' -Level Verbose -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Not -Contain 'chatty'
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
