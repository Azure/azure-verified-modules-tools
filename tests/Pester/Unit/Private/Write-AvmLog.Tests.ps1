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
    $script:savedDiagnosticEnvironment = @{}
    foreach ($name in @('GH_TOKEN', 'GITHUB_REPOSITORY', 'AVM_GITHUB_CHECK_RUN_ID', 'GITHUB_STEP_SUMMARY', 'GITHUB_WORKSPACE')) {
        $script:savedDiagnosticEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
}

AfterAll {
    $env:GITHUB_ACTIONS = $script:savedActions
    $env:RUNNER_DEBUG = $script:savedRunner
    $env:AVM_VERBOSE = $script:savedVerbose
    $env:NO_COLOR = $script:savedNoColor
    $env:CLICOLOR_FORCE = $script:savedColorForce
    foreach ($name in $script:savedDiagnosticEnvironment.Keys) {
        $value = $script:savedDiagnosticEnvironment[$name]
        [Environment]::SetEnvironmentVariable(
            $name,
            $(if ($null -eq $value) { [NullString]::Value } else { $value }),
            'Process')
    }
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Write-AvmLog' {
    BeforeEach {
        $env:GITHUB_ACTIONS = ''
        $env:GITHUB_WORKSPACE = ''
        $env:RUNNER_DEBUG = ''
        $env:AVM_VERBOSE = ''
        Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue
        Remove-Item Env:\CLICOLOR_FORCE -ErrorAction SilentlyContinue
        $env:GH_TOKEN = ''
        $env:GITHUB_REPOSITORY = ''
        $env:AVM_GITHUB_CHECK_RUN_ID = ''
        $env:GITHUB_STEP_SUMMARY = ''
        InModuleScope 'Avm.Authoring' {
            $script:AvmNestedCommandDepth = 0
            $script:AvmGitHubDiagnosticCounts.Warning = 0
            $script:AvmGitHubDiagnosticCounts.Error = 0
            $script:AvmGitHubDiagnosticOverflow.Clear()
        }
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
                $passed = Format-AvmLogText -Text 'passed' -Level Pass
                $failed = Format-AvmLogText -Text 'failed' -Level Fail
                $env:NO_COLOR = '1'
                $plain = Format-AvmLogText -Text 'passed' -Level Pass
                [pscustomobject]@{
                    Passed = $passed
                    Failed = $failed
                    Plain  = $plain
                    Escape = [string]$escape
                }
            }
            $observed.Passed | Should -Be "$($observed.Escape)[32mpassed$($observed.Escape)[0m"
            $observed.Failed | Should -Be "$($observed.Escape)[31mfailed$($observed.Escape)[0m"
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

        It 'includes file, line and column in positioned diagnostics' {
            $observed = InModuleScope 'Avm.Authoring' {
                $env:NO_COLOR = '1'
                $warn = @()
                $info = @()
                Write-AvmLog 'careful' -Level Warning -File 'variables.tf' -Line 168 -WarningVariable warn
                Write-AvmLog 'boom' -Level Error -File 'main.tf' -Line 12 -Column 3 -InformationVariable info
                [pscustomobject]@{
                    Warning = @($warn | ForEach-Object { [string]$_ })
                    Info    = @($info | ForEach-Object { [string]$_.MessageData })
                }
            }

            @($observed.Warning) | Should -Contain 'careful (variables.tf, line 168)'
            @($observed.Info) | Should -Contain 'boom (main.tf, line 12, column 3)'
        }

        It 'includes file-only diagnostics in the message' {
            $warnings = InModuleScope 'Avm.Authoring' {
                $env:NO_COLOR = '1'
                $captured = @()
                Write-AvmLog 'override warning' `
                    -Level Warning `
                    -File 'avm.tflint.override.hcl' `
                    -WarningVariable captured
                @($captured | ForEach-Object { [string]$_ })
            }

            @($warnings) | Should -Contain 'override warning (avm.tflint.override.hcl)'
        }

        It 'ignores leftover GitHub workspace metadata for local <File> diagnostics' -ForEach @(
            @{ File = 'main.tf' }
            @{ File = 'main.bicep' }
        ) {
            $savedWorkspace = $env:GITHUB_WORKSPACE
            try {
                $env:GITHUB_WORKSPACE = $TestDrive
                $observed = InModuleScope 'Avm.Authoring' -Parameters @{ File = $File } {
                    param($File)
                    $warnings = @()
                    Write-AvmLog 'local diagnostic' -Level Warning -File $File -Line 4 -WarningVariable warnings
                    @($warnings | ForEach-Object { [string]$_ })
                }
                $observed | Should -Contain "local diagnostic ($File, line 4)"
            }
            finally { $env:GITHUB_WORKSPACE = $savedWorkspace }
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
                Write-AvmLog 'be careful' -Level Warning -File 'avm/main.bicep' -Line 8 -InformationVariable captured
                Write-AvmLog 'it broke' -Level Error -File 'avm/main.bicep' -Line 12 -InformationVariable +captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain '::warning file=avm/main.bicep,line=8::be careful (avm/main.bicep, line 8)'
            @($messages) | Should -Contain '::error file=avm/main.bicep,line=12::it broke (avm/main.bicep, line 12)'
        }

        It 'renders Fail as plain text without creating an error annotation' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'check failed' -Level Fail -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain 'check failed'
            ($messages -join "`n") | Should -Not -Match ([string][char]27)
            @($messages | Where-Object { $_ -like '::error*' }).Count | Should -Be 0
        }

        It 'uses plain text for ordinary log lines without NO_COLOR' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'passed' -Level Pass -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain 'passed'
            ($messages -join "`n") | Should -Not -Match ([string][char]27)
        }

        It 'honours NO_COLOR for ordinary log lines' {
            $env:NO_COLOR = '1'
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'passed' -Level Pass -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain 'passed'
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

        It 'round-trips literal percent sequences and command delimiters in annotation data and properties' {
            InModuleScope 'Avm.Authoring' {
                $message = "literal %0A %0D %25`r`n::error::not another command"
                $file = "main%2C,%3B;`r`n::error::.bicep"
                $records = @()
                Write-AvmLog $message -Level Error -File $file -Line 2 -InformationVariable records
                $command = [string]$records[0].MessageData
                $command | Should -Not -Match "[`r`n]"
                $parts = $command -split '::', 3
                $property = ($parts[1] -replace '^error file=', '') -replace ',line=2$', ''
                $property.Replace('%0D', "`r").Replace('%0A', "`n").Replace('%3A', ':').
                    Replace('%2C', ',').Replace('%25', '%') | Should -BeExactly $file
                $parts[2].Replace('%0D', "`r").Replace('%0A', "`n").Replace('%25', '%') |
                    Should -BeExactly "$message ($file, line 2)"
            }
        }

        It 'keeps every overflow output line command-safe and retains the original API diagnostic for <Level>' -ForEach @(
            @{ Level = 'Warning' }
            @{ Level = 'Error' }
        ) {
            $env:GH_TOKEN = 'fixture-token'
            $env:GITHUB_REPOSITORY = 'Azure/example'
            $env:AVM_GITHUB_CHECK_RUN_ID = '123'
            InModuleScope 'Avm.Authoring' -Parameters @{ Level = $Level } {
                param($Level)
                $script:overflowBody = $null
                Mock Invoke-AvmGitHubApi {
                    if ($Method -eq 'PATCH') { $script:overflowBody = $Body }
                    return @{}
                }
                1..10 | ForEach-Object { Write-AvmLog "earlier $_" -Level $Level 6>$null }
                $message = "first line %0A`r`n::error::injected command`r::warning::also injected ##[error]legacy"
                $records = @()
                Write-AvmLog $message -Level $Level -File 'main.bicep' -Line 3 -InformationVariable records
                $lines = ([string]$records[0].MessageData) -split '\r\n|\r|\n'
                $lines | Should -HaveCount 3
                foreach ($line in $lines) { $line | Should -Match "^${Level}: " }
                foreach ($line in $lines) { $line | Should -Not -Match '##\[' }
                $script:AvmGitHubDiagnosticOverflow[0].Message | Should -BeExactly "$message (main.bicep, line 3)"
                Send-AvmGitHubDiagnosticOverflow
                $script:overflowBody.output.annotations[0].message |
                    Should -BeExactly "$message (main.bicep, line 3)"
            }
        }

        It 'anchors module-relative and repository-relative paths without concealing outside-workspace diagnostics' {
            $workspace = Join-Path $TestDrive 'workspace'
            $moduleRoot = Join-Path $workspace 'avm' 'res' 'sample'
            $null = New-Item -ItemType Directory -Path $moduleRoot -Force
            $null = New-Item -ItemType File -Path (Join-Path $moduleRoot 'main.bicep')
            $null = New-Item -ItemType File -Path (Join-Path $workspace 'README.md')
            $saved = $env:GITHUB_WORKSPACE
            $env:GITHUB_WORKSPACE = $workspace
            Push-Location -LiteralPath $moduleRoot
            try {
                InModuleScope 'Avm.Authoring' -Parameters @{ Workspace = $workspace } {
                    param($Workspace)
                    $records = @()
                    Write-AvmLog 'ordinary' -Level Warning -File 'main.bicep' -Line 8 -InformationVariable records
                    [string]$records[0].MessageData |
                        Should -BeExactly '::warning file=avm/res/sample/main.bicep,line=8::ordinary (avm/res/sample/main.bicep, line 8)'
                    ConvertTo-AvmAnnotationPath 'avm/res/sample/main.bicep' |
                        Should -BeExactly 'avm/res/sample/main.bicep'
                    ConvertTo-AvmAnnotationPath 'README.md' | Should -BeExactly 'README.md'
                    ConvertTo-AvmAnnotationPath (Join-Path $Workspace 'avm' 'res' 'sample' 'main.bicep') |
                        Should -BeExactly 'avm/res/sample/main.bicep'
                    $outside = [IO.Path]::GetFullPath((Join-Path $Workspace '..' 'outside.bicep')).Replace('\', '/')
                    ConvertTo-AvmAnnotationPath '../../../../outside.bicep' | Should -BeExactly $outside
                    ConvertTo-AvmAnnotationPath $outside | Should -BeExactly $outside
                    1..10 | ForEach-Object { Write-AvmLog "earlier $_" -Level Error 6>$null }
                    Write-AvmLog 'overflow' -Level Error -File 'main.bicep' -Line 9 6>$null
                    $script:AvmGitHubDiagnosticOverflow[0].File | Should -BeExactly 'avm/res/sample/main.bicep'
                    $script:AvmGitHubDiagnosticOverflow[0].Message |
                        Should -BeExactly 'overflow (avm/res/sample/main.bicep, line 9)'
                }
            }
            finally {
                Pop-Location
                $env:GITHUB_WORKSPACE = $saved
            }
        }

        It 'anchors <File> step diagnostics to the checked module rather than the caller directory' -ForEach @(
            @{ File = 'main.tf' }
            @{ File = 'main.bicep' }
        ) {
            $workspace = Join-Path $TestDrive 'step-workspace'
            $moduleRoot = Join-Path $workspace 'avm' 'res' 'sample'
            $null = New-Item -ItemType Directory -Path $moduleRoot -Force
            $savedWorkspace = $env:GITHUB_WORKSPACE
            $env:GITHUB_WORKSPACE = $workspace
            Push-Location -LiteralPath $workspace
            try {
                $records = InModuleScope 'Avm.Authoring' -Parameters @{ File = $File; Root = $moduleRoot } {
                    param($File, $Root)
                    $result = [pscustomobject]@{
                        Issues = @([pscustomobject]@{
                            File = $File; Line = 4; Severity = 'warning'; Message = 'step diagnostic'
                        })
                    }
                    $presented = [Collections.Generic.HashSet[string]]::new()
                    @(Write-AvmStepDiagnostic -Result $result -Name lint -Status pass `
                        -Presented $presented -SourceRoot $Root 6>&1 |
                        ForEach-Object { [string]$_.MessageData })
                }
                $records | Should -Contain "::warning file=avm/res/sample/$File,line=4::step diagnostic (avm/res/sample/$File, line 4)"
            }
            finally {
                Pop-Location
                $env:GITHUB_WORKSPACE = $savedWorkspace
            }
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
            @($messages) | Should -Contain '::error file=tests/unit/a.tftest.hcl,line=17,col=21::assertion failed (tests/unit/a.tftest.hcl, line 17, column 21)'
        }

        It 'F41: normalises Windows separators so GitHub can match the diff' {
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                Write-AvmLog 'assertion failed' -Level Error -File 'tests\unit\a.tftest.hcl' -Line 4 -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            @($messages) | Should -Contain '::error file=tests/unit/a.tftest.hcl,line=4::assertion failed (tests/unit/a.tftest.hcl, line 4)'
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
            @($messages) | Should -Contain '::error file=tests/unit/a.tftest.hcl,line=2::boom (tests/unit/a.tftest.hcl, line 2)'
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
            @($messages) | Should -Contain '::error file=main.tf::file only (main.tf)'
        }

        It 'publishes overflow diagnostics through the Checks API in batches of 50' {
            $env:GH_TOKEN = 'fixture-token'
            $env:GITHUB_REPOSITORY = 'Azure/example'
            $env:AVM_GITHUB_CHECK_RUN_ID = '123'
            $calls = InModuleScope 'Avm.Authoring' {
                $script:AvmGitHubApiCalls = [System.Collections.Generic.List[object]]::new()
                Mock Invoke-AvmGitHubApi {
                    $script:AvmGitHubApiCalls.Add([pscustomobject]@{
                        Endpoint = $Endpoint
                        Method   = $Method
                        Body     = $Body
                    })
                    return @{ output = @{ title = 'PR check'; summary = 'Existing check output.' } }
                }

                for ($index = 1; $index -le 71; $index++) {
                    Write-AvmLog -Message "diagnostic $index" -Level Warning `
                        -File "avm/tests/$index.ps1" -Line $index -Column 2 6>$null
                }
                Send-AvmGitHubDiagnosticOverflow
                @($script:AvmGitHubApiCalls.ToArray())
            }

            $patches = @($calls | Where-Object Method -EQ 'PATCH')
            @($patches).Count | Should -Be 2
            @($patches[0].Body.output.annotations).Count | Should -Be 50
            @($patches[1].Body.output.annotations).Count | Should -Be 11
            $patches[0].Body.output.title | Should -BeExactly 'PR check'
            $patches[0].Body.output.summary | Should -BeExactly 'Existing check output.'
            $patches[0].Body.output.annotations[0].message |
                Should -BeExactly 'diagnostic 11 (avm/tests/11.ps1, line 11, column 2)'
            $patches[0].Body.output.annotations[0].path | Should -BeExactly 'avm/tests/11.ps1'
            $patches[0].Body.output.annotations[0].start_column | Should -Be 2
        }

        It 'writes overflow diagnostics to the step summary when Checks API access is unavailable' {
            $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'diagnostics.md'
            InModuleScope 'Avm.Authoring' {
                Mock Invoke-AvmGitHubApi { throw 'Checks API must not be called without a token.' }
                for ($index = 1; $index -le 11; $index++) {
                    Write-AvmLog -Message "diagnostic $index" -Level Error `
                        -File 'avm/main.tf' -Line $index 6>$null
                }
                Send-AvmGitHubDiagnosticOverflow
            }

            $summary = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
            $summary | Should -Match 'Additional AVM diagnostics'
            $summary | Should -Match 'Checks API access was unavailable'
            $summary | Should -Match 'diagnostic 11'
            $summary | Should -Match 'avm/main\\\.tf'
            $summary | Should -Match 'line 11'
        }

        It 'falls back to the step summary when the Checks API rejects the token' {
            $env:GH_TOKEN = 'fixture-token'
            $env:GITHUB_REPOSITORY = 'Azure/example'
            $env:AVM_GITHUB_CHECK_RUN_ID = '123'
            $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'forbidden-diagnostics.md'
            InModuleScope 'Avm.Authoring' {
                Mock Invoke-AvmGitHubApi {
                    throw [AvmGitHubException]::new('Resource not accessible by integration', 403)
                }
                for ($index = 1; $index -le 11; $index++) {
                    Write-AvmLog -Message "diagnostic $index" -Level Warning `
                        -File 'avm/main.bicep' -Line $index 6>$null
                }
                Send-AvmGitHubDiagnosticOverflow
            }

            $summary = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
            $summary | Should -Match 'HTTP 403'
            $summary | Should -Match 'diagnostic 11'
            $summary | Should -Match 'avm/main\\\.bicep'
            $summary | Should -Match 'line 11'
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

    Context 'inside a nested aggregate command' {
        It 'suppresses routine narration while preserving warnings' {
            $messages = InModuleScope 'Avm.Authoring' {
                @(
                    Invoke-AvmNestedCommand {
                        Write-AvmLog 'nested info' -Level Info
                        Write-AvmLog 'nested pass' -Level Pass
                        Write-AvmLog 'nested warning' -Level Warning
                    } 3>&1 6>&1 | ForEach-Object { [string]$_ }
                )
            }

            @($messages) | Should -Contain 'nested warning'
            @($messages) | Should -Not -Contain 'nested info'
            @($messages) | Should -Not -Contain 'nested pass'
        }

        It 'restores routine narration in verbose mode' {
            $env:AVM_VERBOSE = '1'
            $messages = InModuleScope 'Avm.Authoring' {
                @(
                    Invoke-AvmNestedCommand {
                        Write-AvmLog 'nested info' -Level Info
                        Write-AvmLog 'nested pass' -Level Pass
                    } 6>&1 | ForEach-Object { [string]$_ }
                )
            }

            @($messages) | Should -Contain 'nested info'
            @($messages) | Should -Contain 'nested pass'
        }

        It 'restores the context after a nested command throws' {
            $messages = InModuleScope 'Avm.Authoring' {
                try {
                    Invoke-AvmNestedCommand {
                        throw 'nested failure'
                    }
                }
                catch {
                    $null = $_
                }

                @(Write-AvmLog 'after failure' -Level Info 6>&1 | ForEach-Object { [string]$_ })
            }

            @($messages) | Should -Contain 'after failure'
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

    It 'formats <Seconds> seconds as <Expected> without rounding whole minutes or hours' -ForEach @(
        @{ Seconds = 0; Expected = '0 ms' }
        @{ Seconds = 0.999; Expected = '999 ms' }
        @{ Seconds = 1; Expected = '1.0s' }
        @{ Seconds = 59; Expected = '59.0s' }
        @{ Seconds = 60; Expected = '1m 00s' }
        @{ Seconds = 116.283; Expected = '1m 56s' }
        @{ Seconds = 3599.999; Expected = '59m 59s' }
        @{ Seconds = 3600; Expected = '1h 00m 00s' }
        @{ Seconds = 7199.999; Expected = '1h 59m 59s' }
        @{ Seconds = 86399.999; Expected = '23h 59m 59s' }
        @{ Seconds = 86400; Expected = '24h 00m 00s' }
        @{ Seconds = 90000; Expected = '25h 00m 00s' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Seconds = $Seconds; Expected = $Expected } {
            param($Seconds, $Expected)
            Format-AvmDuration -Duration ([timespan]::FromSeconds($Seconds)) | Should -Be $Expected
        }
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
