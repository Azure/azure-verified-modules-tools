#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    . (Join-Path $PSScriptRoot '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $script:moduleRoot 'Avm.Authoring.psd1')
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmPrCheck' {
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            Mock Assert-AvmGitWorkingTreeClean {}
            Mock Resolve-AvmCommandTool { @() }
            Mock Test-AvmMetadataModules { [pscustomobject]@{ Status = 'pass'; Issues = @() } }
            Mock Initialize-AvmTerraformCommand { [pscustomobject]@{ Status = 'pass' } }
        }
    }

    Context 'Step exclusions' {
        BeforeAll {
            $script:stepCommands = [ordered]@{
                'metadata' = 'Test-AvmMetadataModules'
                'sync' = 'Invoke-AvmSync'
                'format' = 'Invoke-AvmFormat'
                'transform' = 'Invoke-AvmTransform'
                'lint' = 'Invoke-AvmLint'
                'check policy' = 'Invoke-AvmCheckPolicy'
                'check convention' = 'Invoke-AvmCheckConvention'
                'validate' = 'Invoke-AvmTest'
                'docs' = 'Invoke-AvmDocs'
            }
        }

        BeforeEach {
            InModuleScope Avm.Authoring {
                Mock Test-AvmModuleVersion
                Mock Test-AvmDisableSentinel
                Mock Assert-AvmGitWorkingTreeClean
                Mock Resolve-AvmCommandTool
                Mock Write-AvmLog
                Mock Write-AvmResult
                Mock Get-AvmModuleContextInternal {
                    param($Path, $Ecosystem)
                    [pscustomobject]@{
                        Root = $Path
                        Ecosystem = if ($Ecosystem -eq 'auto') { 'terraform' } else { $Ecosystem }
                    }
                }
                Mock Test-AvmMetadataModules { [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmSync { [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmFormat { [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmTransform { [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmLint { [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmTest { [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmDocs {
                    [pscustomobject]@{
                        Status = 'pass'; FilesSelected = 1; FilesProcessed = 1
                        NotRendered = @(); Issues = @()
                    }
                }
            }
        }

        It 'excludes <Step> for <Ecosystem> without invoking it or stopping the remaining steps' -ForEach @(
            foreach ($ecosystem in @('terraform', 'bicep')) {
                foreach ($step in @('metadata', 'sync', 'format', 'transform', 'lint', 'check policy', 'check convention', 'validate', 'docs')) {
                    @{ Step = $step; Ecosystem = $ecosystem }
                }
            }
        ) {
            InModuleScope Avm.Authoring -Parameters @{
                SelectedStep = $Step; SelectedEcosystem = $Ecosystem; Commands = $script:stepCommands
            } {
                param($SelectedStep, $SelectedEcosystem, $Commands)
                $result = Invoke-AvmPrCheck -Path root -Ecosystem $SelectedEcosystem -ExcludeSteps @($SelectedStep) -StopOnFail

                $result.Status | Should -Be 'pass'
                $result.Steps.Step | Should -Be @($Commands.Keys)
                $skipped = @($result.Steps | Where-Object Status -eq 'skipped')
                $skipped | Should -HaveCount 1
                $skipped[0].Step | Should -Be $SelectedStep
                $skipped[0].Error | Should -Be 'Excluded by -ExcludeSteps.'
                $skipped[0].Result | Should -BeNullOrEmpty
                $skipped[0].DurationMs | Should -Be 0
                @($result.Steps | Where-Object Status -eq 'pass') | Should -HaveCount 8
                foreach ($entry in $Commands.GetEnumerator()) {
                    $count = if ($entry.Key -eq $SelectedStep) { 0 } else { 1 }
                    Should -Invoke $entry.Value -Exactly $count
                }
                $initializations = if ($SelectedEcosystem -eq 'terraform' -and $SelectedStep -ne 'validate') { 1 } else { 0 }
                Should -Invoke Initialize-AvmTerraformCommand -Exactly $initializations
                Should -Invoke Resolve-AvmCommandTool -Exactly 1 -ParameterFilter {
                    $Command -eq 'pr-check' -and $ModuleRoot -eq 'root' -and
                    $Ecosystem -eq $SelectedEcosystem -and
                    $ExcludeSteps.Count -eq 1 -and $ExcludeSteps[0] -eq $SelectedStep
                }
                Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter {
                    $Message -like "*: $SelectedStep -> skipped (excluded by -ExcludeSteps)"
                }
            }
        }

        It 'forwards an array through <Flag> and ignores duplicate or mixed-case names' -ForEach @(
            @{ Flag = '-ExcludeSteps' }
            @{ Flag = '--exclude-steps' }
        ) {
            InModuleScope Avm.Authoring -Parameters @{ Flag = $Flag } {
                param($Flag)
                $result = avm pr-check $Flag @('CHECK POLICY', 'Lint', 'lint') -Path root --passthru
                $result.Status | Should -Be 'pass'
                $result.Steps | Should -HaveCount 9
                @($result.Steps | Where-Object Status -eq 'skipped').Step | Should -Be @('lint', 'check policy')
                Should -Invoke Invoke-AvmCheckPolicy -Exactly 0
                Should -Invoke Invoke-AvmLint -Exactly 0
                Should -Invoke Invoke-AvmDocs -Exactly 1
                Should -Invoke Resolve-AvmCommandTool -Exactly 1 -ParameterFilter {
                    ($ExcludeSteps -join '|') -ceq 'CHECK POLICY|Lint|lint'
                }
            }
        }

        It 'preserves the default chain with an explicitly empty array through the dispatcher' {
            InModuleScope Avm.Authoring {
                $result = avm pr-check -ExcludeSteps @() -Path root --passthru
                $result.Status | Should -Be 'pass'
                $result.Steps | Should -HaveCount 9
                @($result.Steps | Where-Object Status -ne 'pass') | Should -HaveCount 0
                Should -Invoke Invoke-AvmCheckPolicy -Exactly 1
                Should -Invoke Resolve-AvmCommandTool -Exactly 1 -ParameterFilter { $ExcludeSteps.Count -eq 0 }
            }
        }

        It 'reports an entirely excluded <Ecosystem> chain as skipped while retaining the version and clean-tree guards' -ForEach @(
            @{ Ecosystem = 'terraform' }, @{ Ecosystem = 'bicep' }
        ) {
            InModuleScope Avm.Authoring -Parameters @{ Commands = $script:stepCommands; SelectedEcosystem = $Ecosystem } {
                param($Commands, $SelectedEcosystem)
                $result = Invoke-AvmPrCheck -Path root -Ecosystem $SelectedEcosystem -ExcludeSteps @($Commands.Keys) -StopOnFail
                $result.Status | Should -Be 'skipped'
                $result.Steps | Should -HaveCount 9
                @($result.Steps | Where-Object Status -ne 'skipped') | Should -HaveCount 0
                foreach ($command in $Commands.Values) {
                    Should -Invoke $command -Exactly 0
                }
                Should -Invoke Initialize-AvmTerraformCommand -Exactly 0
                @(Get-AvmCommandTool -Command 'pr-check' -Ecosystem $SelectedEcosystem -ExcludeSteps @($Commands.Keys)) |
                    Should -HaveCount 0
                Should -Invoke Test-AvmModuleVersion -Exactly 1
                Should -Invoke Assert-AvmGitWorkingTreeClean -Exactly 1 -ParameterFilter { $Path -eq 'root' }
            }
        }

        It 'prepares only the prerequisites required by the remaining <Step> check' -ForEach @(
            @{ Step = 'metadata'; Terraform = $false; Initialize = $false }
            @{ Step = 'sync'; Terraform = $false; Initialize = $false }
            @{ Step = 'format'; Terraform = $true; Initialize = $false }
            @{ Step = 'transform'; Terraform = $true; Initialize = $false }
            @{ Step = 'lint'; Terraform = $true; Initialize = $false }
            @{ Step = 'check policy'; Terraform = $true; Initialize = $false }
            @{ Step = 'check convention'; Terraform = $false; Initialize = $false }
            @{ Step = 'validate'; Terraform = $true; Initialize = $true }
            @{ Step = 'docs'; Terraform = $false; Initialize = $false }
        ) {
            InModuleScope Avm.Authoring -Parameters @{
                SelectedStep = $Step; NeedsTerraform = $Terraform; NeedsInitialization = $Initialize
                Commands = $script:stepCommands
            } {
                param($SelectedStep, $NeedsTerraform, $NeedsInitialization, $Commands)
                $exclusions = @($Commands.Keys | Where-Object { $_ -ne $SelectedStep })
                $result = Invoke-AvmPrCheck -Path root -Ecosystem terraform -ExcludeSteps $exclusions
                $result.Status | Should -Be 'pass'
                $result.Steps.Step | Should -Be @($Commands.Keys)
                @($result.Steps | Where-Object Status -eq 'pass').Step | Should -Be $SelectedStep
                @($result.Steps | Where-Object Status -eq 'skipped') | Should -HaveCount 8
                $tools = @(Get-AvmCommandTool -Command 'pr-check' -Ecosystem terraform -ExcludeSteps $exclusions)
                ('terraform' -in $tools) | Should -Be $NeedsTerraform
                Should -Invoke Initialize-AvmTerraformCommand -Exactly ([int]$NeedsInitialization)
                foreach ($entry in $Commands.GetEnumerator()) {
                    $count = if ($entry.Key -eq $SelectedStep) { 1 } else { 0 }
                    Should -Invoke $entry.Value -Exactly $count
                }
                if ($NeedsInitialization) {
                    Should -Invoke Invoke-AvmTest -Exactly 1 -ParameterFilter { $UseExistingInit }
                }
            }
        }

        It 'keeps prerequisite ordering and cache reuse for the <Chain> chain' -ForEach @(
            @{ Chain = 'normal'; Exclusions = @() }
            @{ Chain = 'fork'; Exclusions = @('check policy') }
        ) {
            InModuleScope Avm.Authoring -Parameters @{ Exclusions = $Exclusions } {
                param($Exclusions)
                $script:order = [Collections.Generic.List[string]]::new()
                Mock Test-AvmMetadataModules { $script:order.Add('metadata'); [pscustomobject]@{ Status = 'pass' } }
                Mock Initialize-AvmTerraformCommand { $script:order.Add('initialize'); [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmSync { $script:order.Add('sync'); [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmTest { $script:order.Add('validate'); [pscustomobject]@{ Status = 'pass' } }
                $result = Invoke-AvmPrCheck -Path root -Ecosystem terraform -ExcludeSteps $Exclusions
                $result.Status | Should -Be 'pass'
                $result.Steps | Should -HaveCount 9
                @($script:order) | Should -Be @('metadata', 'initialize', 'sync', 'validate')
                Should -Invoke Initialize-AvmTerraformCommand -Exactly 1 -ParameterFilter { $Command -eq 'pr-check' }
                Should -Invoke Invoke-AvmTest -Exactly 1 -ParameterFilter { $UseExistingInit }
            }
        }

        It 'aborts without running dependent checks after initialization <Failure>' -ForEach @(
            @{ Failure = 'configuration error'; Status = 'fail' }
            @{ Failure = 'unsupported error'; Status = 'fail' }
            @{ Failure = 'unexpected error'; Status = 'error' }
            @{ Failure = 'retry detail'; Status = 'error' }
            @{ Failure = 'failed result'; Status = 'error' }
            @{ Failure = 'skipped result'; Status = 'error' }
            @{ Failure = 'missing result'; Status = 'error' }
            @{ Failure = 'array status'; Status = 'error' }
        ) {
            InModuleScope Avm.Authoring -Parameters @{ Failure = $Failure; Expected = $Status } {
                param($Failure, $Expected)
                Mock Initialize-AvmTerraformCommand {
                    switch ($Failure) {
                        'configuration error' { throw [AvmConfigurationException]::new('Invalid initialization configuration.') }
                        'unsupported error' { throw [AvmNotSupportedException]::new('Initialization is unavailable.') }
                        'unexpected error' { throw [InvalidOperationException]::new('Initialization failed.') }
                        'retry detail' {
                            $record = [Management.Automation.ErrorRecord]::new(
                                [AvmProcessException]::new('Raw transport failure.'), 'AVM1020',
                                [Management.Automation.ErrorCategory]::ConnectionError, $null)
                            $record.ErrorDetails = [Management.Automation.ErrorDetails]::new(
                                'Initialization download failed. Run with -Verbose for technical details.')
                            throw $record
                        }
                        'failed result' { [pscustomobject]@{ Status = 'fail' } }
                        'skipped result' { [pscustomobject]@{ Status = 'skipped' } }
                        'missing result' { $null }
                        'array status' { [pscustomobject]@{ Status = @('pass') } }
                    }
                }
                $result = Invoke-AvmPrCheck -Path root -Ecosystem terraform
                $result.Status | Should -Be $Expected
                $result.Steps.Step | Should -Be @('metadata', 'sync')
                $result.Steps[-1].Error | Should -Match '^Terraform initialization prerequisite failed:'
                if ($Failure -eq 'retry detail') {
                    $result.Steps[-1].Error | Should -Be 'Terraform initialization prerequisite failed: Initialization download failed. Run with -Verbose for technical details.'
                }
                Should -Invoke Initialize-AvmTerraformCommand -Exactly 1
                Should -Invoke Invoke-AvmSync -Exactly 0
                Should -Invoke Invoke-AvmTransform -Exactly 0
                Should -Invoke Invoke-AvmTest -Exactly 0
                Should -Invoke Invoke-AvmDocs -Exactly 0
            }
        }

        It 'rejects <Case> before resolving tools or executing steps' -ForEach @(
            @{ Case = 'unknown step names'; Exclusions = @('format', 'conftest') }
            @{ Case = 'empty step names'; Exclusions = @('') }
            @{ Case = 'whitespace step names'; Exclusions = @(' ') }
            @{ Case = 'null arrays'; Exclusions = $null }
        ) {
            InModuleScope Avm.Authoring -Parameters @{ Exclusions = $Exclusions } {
                param($Exclusions)
                { Invoke-AvmPrCheck -Path root -ExcludeSteps $Exclusions } | Should -Throw
                Should -Invoke Test-AvmModuleVersion -Exactly 0
                Should -Invoke Get-AvmModuleContextInternal -Exactly 0
                Should -Invoke Resolve-AvmCommandTool -Exactly 0
                Should -Invoke Test-AvmMetadataModules -Exactly 0
            }
        }

        It 'still aborts on invalid metadata when only policy is excluded' {
            InModuleScope Avm.Authoring {
                Mock Test-AvmMetadataModules { [pscustomobject]@{ Status = 'fail' } }
                $result = Invoke-AvmPrCheck -Path root -ExcludeSteps 'check policy'
                $result.Status | Should -Be 'fail'
                $result.Steps.Step | Should -Be 'metadata'
                Should -Invoke Initialize-AvmTerraformCommand -Exactly 0
                Should -Invoke Invoke-AvmSync -Exactly 0
            }
        }

        It 'retains fail-soft and StopOnFail behavior for non-excluded steps with StopOnFail=<Stop>' -ForEach @(
            @{ Stop = $false; Count = 9; DocsCalls = 1 }
            @{ Stop = $true; Count = 5; DocsCalls = 0 }
        ) {
            InModuleScope Avm.Authoring -Parameters @{ Stop = $Stop; Count = $Count; DocsCalls = $DocsCalls } {
                param($Stop, $Count, $DocsCalls)
                Mock Invoke-AvmLint { [pscustomobject]@{ Status = 'fail' } }
                $result = Invoke-AvmPrCheck -Path root -ExcludeSteps @('transform', 'check policy') -StopOnFail:$Stop
                $result.Status | Should -Be 'fail'
                $result.Steps | Should -HaveCount $Count
                Should -Invoke Invoke-AvmTransform -Exactly 0
                Should -Invoke Invoke-AvmCheckPolicy -Exactly 0
                Should -Invoke Invoke-AvmDocs -Exactly $DocsCalls
            }
        }

        It 'still requires inspectable Bicep docs when another required step is excluded' {
            InModuleScope Avm.Authoring {
                Mock Invoke-AvmDocs { [pscustomobject]@{ Status = 'skipped' } }
                $result = Invoke-AvmPrCheck -Path root -Ecosystem bicep -ExcludeSteps 'check policy'
                $result.Status | Should -Be 'fail'
                ($result.Steps | Where-Object Step -eq 'docs').Error | Should -Match 'Required Bicep docs returned skipped'
                ($result.Steps | Where-Object Step -eq 'check policy').Status | Should -Be 'skipped'
            }
        }
    }

    It 'is wired into the verb registry as "avm pr-check"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 1 -and $_.Path[0] -eq 'pr-check' }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmPrCheck'
    }

    It 'suppresses nested routine narration unless verbose or runner debug is enabled' {
        $dir = Join-Path $TestDrive ("prcheck-output-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $observed = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $saved = @{
                Actions = $env:GITHUB_ACTIONS
                Runner  = $env:RUNNER_DEBUG
                Verbose = $env:AVM_VERBOSE
            }
            $env:GITHUB_ACTIONS = ''
            $env:RUNNER_DEBUG = ''
            $env:AVM_VERBOSE = ''
            try {
                Mock Get-AvmModuleContextInternal {
                    [pscustomobject]@{
                        Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                    }
                }
                Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
                Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmLint {
                    Write-AvmLog 'nested lint info' -Level Info
                    Write-AvmLog 'nested lint pass' -Level Pass
                    Write-AvmLog 'nested lint warning' -Level Warning
                    [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' }
                }
                Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmDocs {
                    [pscustomobject]@{
                        Engine = 'bicep'; Status = 'pass'; FilesSelected = 0
                        FilesProcessed = 0; NotRendered = @(); Issues = @()
                    }
                }

                $defaultOutput = @(Invoke-AvmPrCheck -Path $D 3>&1 6>&1)

                $verboseOutput = @(Invoke-AvmPrCheck -Path $D -Verbose 4>$null 6>&1)

                $env:RUNNER_DEBUG = '1'
                $debugOutput = @(Invoke-AvmPrCheck -Path $D 4>$null 6>&1)

                [pscustomobject]@{
                    DefaultInfo = @(
                        $defaultOutput |
                            Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                            ForEach-Object { [string]$_.MessageData }
                    )
                    DefaultWarnings = @(
                        $defaultOutput |
                            Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
                            ForEach-Object { [string]$_ }
                    )
                    VerboseInfo = @(
                        $verboseOutput |
                            Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                            ForEach-Object { [string]$_.MessageData }
                    )
                    DebugInfo = @(
                        $debugOutput |
                            Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                            ForEach-Object { [string]$_.MessageData }
                    )
                }
            }
            finally {
                $env:GITHUB_ACTIONS = $saved.Actions
                $env:RUNNER_DEBUG = $saved.Runner
                $env:AVM_VERBOSE = $saved.Verbose
            }
        }

        ($observed.DefaultInfo -join "`n") | Should -Match 'step 5/9: lint'
        @($observed.DefaultWarnings) | Should -Contain 'nested lint warning'
        @($observed.DefaultInfo) | Should -Not -Contain 'nested lint info'
        @($observed.DefaultInfo) | Should -Not -Contain 'nested lint pass'
        @($observed.VerboseInfo) | Should -Contain 'nested lint info'
        @($observed.VerboseInfo) | Should -Contain 'nested lint pass'
        @($observed.DebugInfo) | Should -Contain 'nested lint info'
        @($observed.DebugInfo) | Should -Contain 'nested lint pass'
    }

    It 'preserves an inline deprecated-interface warning through nested lint and omits its green summary duplicate' {
        $dir = Join-Path $TestDrive ("prcheck-deprecation-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $observed = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $savedActions = $env:GITHUB_ACTIONS
            $savedRunner = $env:RUNNER_DEBUG
            $savedVerbose = $env:AVM_VERBOSE
            try {
                $env:GITHUB_ACTIONS = ''
                $env:RUNNER_DEBUG = ''
                $env:AVM_VERBOSE = ''
                Mock Get-AvmModuleContextInternal {
                    [pscustomobject]@{
                        Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                    }
                }
                Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
                Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
                Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
                Mock Invoke-AvmLint {
                    $issue = [pscustomobject]@{
                        File = 'variables.tf'; Line = 17; Column = 5
                        Severity = 'notice'; Code = 'avm_interface_lock_deprecated'
                        Message = 'Use the canonical lock interface.'
                    }
                    if (Test-AvmInlineAvmNotice -Issue $issue) {
                        Write-AvmLog `
                            -Message ('[{0}] {1}' -f $issue.Code, $issue.Message) `
                            -Level Warning `
                            -File $issue.File `
                            -Line $issue.Line `
                            -Column $issue.Column
                        Register-AvmPresentedIssue -Issue $issue
                    }
                    [pscustomobject]@{
                        Engine = 'terraform'; Status = 'pass'; Issues = @($issue)
                    }
                }
                Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
                Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
                Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
                Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }

                $output = @(Invoke-AvmPrCheck -Path $D 3>&1 6>&1)
                $result = $output |
                    Where-Object { $null -ne $_.PSObject.Properties['Steps'] } |
                    Select-Object -Last 1
                $warnings = @(
                    $output |
                        Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
                        ForEach-Object { [string]$_ }
                )
                $summaryInfo = @()
                Write-AvmResult `
                    -Result $result `
                    -Verb 'pr-check' `
                    -InformationVariable summaryInfo

                [pscustomobject]@{
                    Result = $result
                    Warnings = $warnings
                    Summary = @($summaryInfo | ForEach-Object { [string]$_.MessageData })
                }
            }
            finally {
                $env:GITHUB_ACTIONS = $savedActions
                $env:RUNNER_DEBUG = $savedRunner
                $env:AVM_VERBOSE = $savedVerbose
            }
        }

        $observed.Result.Status | Should -Be 'pass'
        $lintStep = $observed.Result.Steps | Where-Object Step -eq 'lint'
        $lintStep.Status | Should -Be 'pass'
        $lintStep.Result.Issues[0].Severity | Should -Be 'notice'
        @($observed.Warnings).Count | Should -Be 1
        $observed.Warnings[0] | Should -Match '\[avm_interface_lock_deprecated\] Use the canonical lock interface\.'
        ($observed.Summary -join "`n") | Should -Match '\[pass\] lint'
        ($observed.Summary -join "`n") | Should -Not -Match 'avm_interface_lock_deprecated|canonical lock'
    }

    It 'rejects a dirty working tree before invoking any gauntlet step' {
        $dir = Join-Path $TestDrive ("prcheck-dirty-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $probe = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Assert-AvmGitWorkingTreeClean {
                throw [AvmConfigurationException]::new('Pr-check requires a clean working tree.')
            }
            Mock Invoke-AvmSync { throw 'No gauntlet step may run.' }

            try {
                $null = Invoke-AvmPrCheck -Path $D
            }
            catch {
                [pscustomobject]@{
                    ErrorName = $_.Exception.GetType().Name
                    Message = $_.Exception.Message
                }
            }

            Should -Invoke Assert-AvmGitWorkingTreeClean -Exactly 1 -ParameterFilter { $Path -eq $D }
            Should -Invoke Resolve-AvmCommandTool -Exactly 0
            Should -Invoke Invoke-AvmSync -Exactly 0
        }

        $probe.ErrorName | Should -Be 'AvmConfigurationException'
        $probe.Message | Should -Match 'clean working tree'
    }

    It 'resolves <Ecosystem> tools after the clean-worktree check and before metadata' -TestCases @(
        @{ Ecosystem = 'bicep'; Kind = 'bicep-module' }
        @{ Ecosystem = 'terraform'; Kind = 'terraform-module-repo' }
    ) {
        param($Ecosystem, $Kind)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $probe = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir; E = $Ecosystem; K = $Kind } {
            param($D, $E, $K)
            $script:resolutionOrder = [System.Collections.Generic.List[string]]::new()
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = $K; Root = $D; Ecosystem = $E; Source = 'path-heuristic' }
            }
            Mock Assert-AvmGitWorkingTreeClean { $script:resolutionOrder.Add('clean') }
            Mock Resolve-AvmCommandTool { $script:resolutionOrder.Add('tools'); @() }
            Mock Test-AvmMetadataModules {
                $script:resolutionOrder.Add('metadata')
                [pscustomobject]@{ Status = 'fail'; Issues = @() }
            }
            Mock Invoke-AvmSync { throw [System.InvalidOperationException]::new('Sync must not run.') }

            $result = Invoke-AvmPrCheck -Path $D -AllowPathFallback -SkipModuleVersionCheck
            Should -Invoke Resolve-AvmCommandTool -Exactly 1 -ParameterFilter {
                $Command -eq 'pr-check' -and $Ecosystem -eq $E -and $AllowPathFallback
            }
            [pscustomobject]@{ Order = $script:resolutionOrder.ToArray(); Result = $result }
        }

        $probe.Order | Should -Be @('clean', 'tools', 'metadata')
        $probe.Result.Status | Should -Be 'fail'
        $probe.Result.Steps.Step | Should -Be @('metadata')
    }

    It 'composes all nine steps in order on a passing chain; the terraform-only sync step is skipped for bicep' {
        $dir = Join-Path $TestDrive ("prcheck-pass-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs {
                [pscustomobject]@{
                    Engine = 'bicep'; Status = 'pass'; FilesSelected = 0
                    FilesProcessed = 0; NotRendered = @('README.md')
                    Issues = @([pscustomobject]@{ Severity = 'warning'; Code = 'avm.bicep.docs-no-source' })
                }
            }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status                    | Should -Be 'pass'
        $result.Ecosystem                 | Should -Be 'bicep'
        $result.Steps.Count               | Should -Be 9
        $result.Steps.Step | Should -Be @('metadata', 'sync', 'format', 'transform', 'lint', 'check policy', 'check convention', 'validate', 'docs')
        $result.Steps[1].Status           | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'docs').Result.NotRendered |
            Should -Contain 'README.md'
        InModuleScope Avm.Authoring {
            Should -Invoke Test-AvmMetadataModules -Exactly 1 -ParameterFilter {
                $Context.Ecosystem -eq 'bicep'
            }
            Should -Invoke Invoke-AvmTransform -Exactly 1 -ParameterFilter {
                $Ecosystem -eq 'bicep' -and $CheckDrift
            }
        }
        ($result.Steps | Where-Object Step -ne 'sync' | ForEach-Object Status | Select-Object -Unique) | Should -Be 'pass'
    }

    It 'runs every managed-content step in drift mode so a CI auto-fix cannot report a pass' {
        $dir = Join-Path $TestDrive ("prcheck-drift-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }

            Invoke-AvmPrCheck -Path $D | Out-Null

            # All four steps that rewrite tracked files must gate, or the fix is
            # made in the throwaway runner copy and thrown away with it.
            Should -Invoke Invoke-AvmSync -Exactly 1 -ParameterFilter { $CheckDrift -eq $true }
            Should -Invoke Invoke-AvmFormat -Exactly 1 -ParameterFilter { $CheckDrift -eq $true }
            Should -Invoke Invoke-AvmTransform -Exactly 1 -ParameterFilter { $CheckDrift -eq $true }
            Should -Invoke Invoke-AvmDocs -Exactly 1 -ParameterFilter { $CheckDrift -eq $true }
            Should -Invoke Invoke-AvmCheckConvention -Exactly 1 -ParameterFilter {
                -not $Fix -and -not $FixableOnly
            }
        }
    }

    It 'fails unimplemented Bicep policy and convention while preserving unrelated skips' {
        $dir = Join-Path $TestDrive ("prcheck-skip-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { throw [AvmNotSupportedException]::new('transform not wired yet') }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { throw [AvmNotSupportedException]::new('check policy not wired yet') }
            Mock Invoke-AvmCheckConvention { throw [AvmNotSupportedException]::new('check convention not wired yet') }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs {
                [pscustomobject]@{
                    Engine = 'bicep'; Status = 'pass'; FilesSelected = 0
                    FilesProcessed = 0; NotRendered = @(); Issues = @()
                }
            }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status                                  | Should -Be 'fail'
        $result.Steps.Count                             | Should -Be 9
        ($result.Steps | Where-Object Status -eq 'skipped').Count | Should -Be 2
        ($result.Steps | Where-Object Step -eq 'sync').Status              | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'transform').Status         | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'check policy').Status      | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'check convention').Status  | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'check policy').Error       | Should -Match 'not implemented'
        ($result.Steps | Where-Object Step -eq 'docs').Status              | Should -Be 'pass'
    }

    It 'fails when a required Bicep static check returns skipped instead of throwing' {
        $dir = Join-Path $TestDrive ("prcheck-required-skip-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep' }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('not applicable') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Status = 'skipped' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Status = 'skipped' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmDocs {
                [pscustomobject]@{
                    Status = 'pass'; FilesSelected = 0; FilesProcessed = 0
                    NotRendered = @(); Issues = @()
                }
            }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'sync').Status | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'check policy').Status | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'check convention').Status | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'check policy').Error | Should -Match 'returned skipped'
    }

    It 'fails when required Bicep static checks return no status or an invalid status' {
        $dir = Join-Path $TestDrive ("prcheck-required-status-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep' }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('not applicable') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy {}
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Status = 'unknown' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmDocs {
                [pscustomobject]@{
                    Status = 'pass'; FilesSelected = 0; FilesProcessed = 0
                    NotRendered = @(); Issues = @()
                }
            }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'sync').Status | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'check policy').Status | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'check policy').Error | Should -Match 'returned no status'
        ($result.Steps | Where-Object Step -eq 'check convention').Status | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'check convention').Error | Should -Match 'invalid status'
    }

    It 'fails when Bicep docs are <Case>' -TestCases @(
        @{ Case = 'unsupported'; Mode = 'unsupported'; Ecosystem = 'bicep'; Expected = 'not implemented' }
        @{ Case = 'skipped'; Mode = 'skipped'; Ecosystem = 'bicep'; Expected = 'returned skipped' }
        @{ Case = 'missing'; Mode = 'missing'; Ecosystem = 'bicep'; Expected = 'returned no status' }
        @{ Case = 'invalid'; Mode = 'invalid'; Ecosystem = 'bicep'; Expected = 'invalid status' }
        @{ Case = 'an array status'; Mode = 'array'; Ecosystem = 'bicep'; Expected = 'invalid status' }
        @{ Case = 'skipped under mixed-case Bicep'; Mode = 'skipped'; Ecosystem = 'Bicep'; Expected = 'returned skipped' }
    ) {
        param($Case, $Mode, $Ecosystem, $Expected)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir; M = $Mode; E = $Ecosystem } {
            param($D, $M, $E)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'bicep-module'; Root = $D; Ecosystem = $E }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('not applicable') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmDocs {
                switch ($M) {
                    'unsupported' { throw [AvmNotSupportedException]::new('Bicep docs unavailable') }
                    'skipped' { [pscustomobject]@{ Status = 'skipped' } }
                    'missing' { $null }
                    'invalid' { [pscustomobject]@{ Status = 'unknown' } }
                    'array' { [pscustomobject]@{ Status = @('pass') } }
                }
            }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status | Should -BeExactly 'fail'
        ($result.Steps | Where-Object Step -eq 'sync').Status | Should -BeExactly 'skipped'
        $docs = $result.Steps | Where-Object Step -eq 'docs'
        $docs.Status | Should -BeExactly 'fail'
        $docs.Error | Should -Match $Expected
    }

    It 'fails when passing Bicep docs have <Case>' -TestCases @(
        @{ Case = 'missing shape'; Expected = 'valid render counts' }
        @{ Case = 'partial render'; Expected = 'rendered 1 of 2' }
        @{ Case = 'negative counts'; Expected = 'valid render counts' }
        @{ Case = 'error issue'; Expected = 'error or unclassified issue' }
        @{ Case = 'unclassified issue'; Expected = 'error or unclassified issue' }
        @{ Case = 'null issue severity'; Expected = 'error or unclassified issue' }
        @{ Case = 'unknown issue severity'; Expected = 'error or unclassified issue' }
        @{ Case = 'array issue severity'; Expected = 'error or unclassified issue' }
    ) {
        param($Case, $Expected)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir; C = $Case } {
            param($D, $C)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep' }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('not applicable') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmDocs {
                switch ($C) {
                    'missing shape' { [pscustomobject]@{ Status = 'pass' } }
                    'partial render' {
                        [pscustomobject]@{
                            Status = 'pass'; FilesSelected = 2; FilesProcessed = 1
                            NotRendered = @(); Issues = @()
                        }
                    }
                    'negative counts' {
                        [pscustomobject]@{
                            Status = 'pass'; FilesSelected = -1; FilesProcessed = -1
                            NotRendered = @(); Issues = @()
                        }
                    }
                    'error issue' {
                        [pscustomobject]@{
                            Status = 'pass'; FilesSelected = 1; FilesProcessed = 1
                            NotRendered = @(); Issues = @([pscustomobject]@{ Severity = 'error' })
                        }
                    }
                    'unclassified issue' {
                        [pscustomobject]@{
                            Status = 'pass'; FilesSelected = 1; FilesProcessed = 1
                            NotRendered = @(); Issues = @([pscustomobject]@{ Message = 'unknown' })
                        }
                    }
                    'null issue severity' {
                        [pscustomobject]@{
                            Status = 'pass'; FilesSelected = 1; FilesProcessed = 1
                            NotRendered = @(); Issues = @([pscustomobject]@{ Severity = $null })
                        }
                    }
                    'unknown issue severity' {
                        [pscustomobject]@{
                            Status = 'pass'; FilesSelected = 1; FilesProcessed = 1
                            NotRendered = @(); Issues = @([pscustomobject]@{ Severity = 'unknown' })
                        }
                    }
                    'array issue severity' {
                        [pscustomobject]@{
                            Status = 'pass'; FilesSelected = 1; FilesProcessed = 1
                            NotRendered = @(); Issues = @([pscustomobject]@{ Severity = @('warning') })
                        }
                    }
                }
            }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status | Should -BeExactly 'fail'
        $docs = $result.Steps | Where-Object Step -eq 'docs'
        $docs.Status | Should -BeExactly 'fail'
        $docs.Error | Should -Match $Expected
    }

    It 'keeps Bicep policy and convention required with a mixed-case ecosystem' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'bicep-module'; Root = $D; Ecosystem = 'Bicep' }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('not applicable') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Status = 'skipped' } }
            Mock Invoke-AvmCheckConvention { throw [AvmNotSupportedException]::new('not supported') }
            Mock Invoke-AvmTest { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmDocs {
                [pscustomobject]@{
                    Status = 'pass'; FilesSelected = 1; FilesProcessed = 1
                    NotRendered = @(); Issues = @()
                }
            }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status | Should -BeExactly 'fail'
        ($result.Steps | Where-Object Step -eq 'check policy').Status | Should -BeExactly 'fail'
        ($result.Steps | Where-Object Step -eq 'check convention').Status | Should -BeExactly 'fail'
        ($result.Steps | Where-Object Step -eq 'docs').Status | Should -BeExactly 'pass'
    }

    It 'flips overall to fail when any step returns Status=fail but continues by default' {
        $dir = Join-Path $TestDrive ("prcheck-fail-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'fail' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs {
                [pscustomobject]@{
                    Engine = 'bicep'; Status = 'pass'; FilesSelected = 0
                    FilesProcessed = 0; NotRendered = @(); Issues = @()
                }
            }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status                                | Should -Be 'fail'
        $result.Steps.Count                           | Should -Be 9
        ($result.Steps | Where-Object Step -eq 'lint').Status | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'docs').Status | Should -Be 'pass'
    }

    It '-StopOnFail aborts the chain after the first Status=fail' {
        $dir = Join-Path $TestDrive ("prcheck-stop-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'fail' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs {
                [pscustomobject]@{
                    Engine = 'bicep'; Status = 'pass'; FilesSelected = 0
                    FilesProcessed = 0; NotRendered = @(); Issues = @()
                }
            }
            Invoke-AvmPrCheck -Path $D -StopOnFail
        }

        $result.Status                       | Should -Be 'fail'
        $result.Steps.Count                  | Should -Be 5
        $result.Steps[-1].Step               | Should -Be 'lint'
        $result.Steps[-1].Status             | Should -Be 'fail'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmCheckPolicy -Times 0 -Exactly
            Should -Invoke Invoke-AvmCheckConvention -Times 0 -Exactly
            Should -Invoke Invoke-AvmTest -Times 0 -Exactly
            Should -Invoke Invoke-AvmDocs -Times 0 -Exactly
        }
    }

    It 'aborts the chain and flips overall to error on a thrown non-Avm exception' {
        $dir = Join-Path $TestDrive ("prcheck-err-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { throw [System.InvalidOperationException]::new('engine blew up') }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs {
                [pscustomobject]@{
                    Engine = 'bicep'; Status = 'pass'; FilesSelected = 0
                    FilesProcessed = 0; NotRendered = @(); Issues = @()
                }
            }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status                       | Should -Be 'error'
        $result.Steps.Count                  | Should -Be 4
        $result.Steps[-1].Step               | Should -Be 'transform'
        $result.Steps[-1].Status             | Should -Be 'error'
        $result.Steps[-1].Error              | Should -Match 'engine blew up'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmLint -Times 0 -Exactly
            Should -Invoke Invoke-AvmDocs -Times 0 -Exactly
        }
    }

    It 'composes all nine steps in order on a passing chain (terraform), running the drift-check sync first and forwarding the ecosystem to every step' {
        $dir = Join-Path $TestDrive ("prcheck-tf-pass-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTestUnit { throw 'pr-check must not run the standalone unit tier' }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            $r = Invoke-AvmPrCheck -Path $D -ThrottleLimit 5

            # sync runs first in drift-check mode: -CheckDrift is forwarded via
            # the step's ExtraArgs so CI treats stale governed files as a fail.
            Should -Invoke Invoke-AvmSync            -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' -and $CheckDrift }
            Should -Invoke Initialize-AvmTerraformCommand -Exactly 1 -ParameterFilter {
                $Context.Root -eq $D -and $Command -eq 'pr-check'
            }
            Should -Invoke Invoke-AvmFormat          -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmTransform       -Exactly 1 -ParameterFilter {
                $Ecosystem -eq 'terraform' -and $ThrottleLimit -eq 5
            }
            Should -Invoke Invoke-AvmLint            -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' -and $ThrottleLimit -eq 5 }
            Should -Invoke Invoke-AvmCheckPolicy     -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' -and $ThrottleLimit -eq 5 }
            Should -Invoke Invoke-AvmCheckConvention -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmTest            -Exactly 1 -ParameterFilter {
                $Ecosystem -eq 'terraform' -and $UseExistingInit
            }
            Should -Invoke Invoke-AvmTestUnit        -Times 0 -Exactly
            Should -Invoke Invoke-AvmDocs            -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }

            $r
        }

        $result.Status                    | Should -Be 'pass'
        $result.Ecosystem                 | Should -Be 'terraform'
        $result.Steps.Count               | Should -Be 9
        $result.Steps.Step | Should -Be @('metadata', 'sync', 'format', 'transform', 'lint', 'check policy', 'check convention', 'validate', 'docs')
        ($result.Steps | ForEach-Object Status | Select-Object -Unique) | Should -Be 'pass'
    }

    It 'renders deprecated interface notices while lint and pr-check remain pass' {
        $dir = Join-Path $TestDrive ("prcheck-tf-notice-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $observed = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint {
                [pscustomobject]@{
                    Engine = 'terraform'
                    Status = 'pass'
                    Issues = @([pscustomobject]@{
                            Severity = 'notice'
                            File     = 'variables.tf'
                            Line     = 7
                            Column   = 1
                            Code     = 'avm_interface_lock_deprecated'
                            Message  = 'lock uses deprecated interface variant 1'
                        })
                }
            }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }

            $result = Invoke-AvmPrCheck -Path $D
            [pscustomobject]@{
                Result = $result
                Lines  = @(ConvertTo-AvmResultLine -Result @($result) -Verb 'pr-check')
            }
        }

        $observed.Result.Status | Should -Be 'pass'
        $lintStep = $observed.Result.Steps | Where-Object Step -eq 'lint'
        $lintStep.Status | Should -Be 'pass'
        $lintStep.Result.Status | Should -Be 'pass'
        $lintStep.Result.Issues.Count | Should -Be 1
        $lintStep.Result.Issues[0].Code | Should -Be 'avm_interface_lock_deprecated'
        ($observed.Lines -join "`n") | Should -Match 'notice variables\.tf:7:1 \[avm_interface_lock_deprecated\]'
        ($observed.Lines -join "`n") | Should -Match 'lock uses deprecated interface variant 1'
    }

    It 'reports the stub terraform engines (transform/check policy/check convention) as skipped and keeps overall pass; the terraform sync step runs' {
        $dir = Join-Path $TestDrive ("prcheck-tf-skip-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { throw [AvmNotSupportedException]::new('transform not wired yet') }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { throw [AvmNotSupportedException]::new('check policy not wired yet') }
            Mock Invoke-AvmCheckConvention { throw [AvmNotSupportedException]::new('check convention not wired yet') }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status                                                     | Should -Be 'pass'
        $result.Ecosystem                                                  | Should -Be 'terraform'
        $result.Steps.Count                                                | Should -Be 9
        ($result.Steps | Where-Object Status -eq 'skipped').Count          | Should -Be 3
        ($result.Steps | Where-Object Step -eq 'sync').Status              | Should -Be 'pass'
        ($result.Steps | Where-Object Step -eq 'transform').Status         | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'check policy').Status      | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'check convention').Status  | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'docs').Status              | Should -Be 'pass'
    }

    It 'preserves an unsupported Terraform docs step as skipped' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{ Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform' }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Status = 'pass' } }
            Mock Invoke-AvmDocs { throw [AvmNotSupportedException]::new('not applicable') }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status | Should -BeExactly 'pass'
        ($result.Steps | Where-Object Step -eq 'docs').Status | Should -BeExactly 'skipped'
    }

    It 'does not run the unit tier as part of pre-commit, which stays offline and init-free' {
        $dir = Join-Path $TestDrive ("precommit-nounit-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTestUnit { throw 'pre-commit must not run the unit tier' }
            Invoke-AvmPreCommit -Path $D
        }

        $result.Status | Should -Be 'pass'
        $result.Steps.Step | Should -Not -Contain 'unit test'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTestUnit -Times 0 -Exactly
        }
    }

    # F39: 'skipped' means the verb does not apply to this ecosystem. It must not
    # also mean 'your repo is misconfigured', because a skip renders as a benign
    # gauntlet pass - which is exactly how a step that never ran looks green.
    It 'F39: fails the gauntlet on a configuration error but skips an unsupported verb' {
        $dir = Join-Path $TestDrive ("prcheck-f39-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint { throw [AvmConfigurationException]::new('AVM_MIRROR is not a valid absolute URL') }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D
        }

        ($result.Steps | Where-Object Step -eq 'lint').Status | Should -Be 'fail'
        $result.Status | Should -Be 'fail'

        # 'fail' must not abort the chain the way 'error' does - the remaining
        # steps still run so one bad config does not mask the next.
        $result.Steps.Step | Should -Contain 'docs'
    }
}