#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot 'build' 'avm.build.ps1'), [ref]$tokens, [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'script:Invoke-ScriptAnalyzerWithRetry'
    }, $true)
    $definition | Should -Not -BeNullOrEmpty
    . ([scriptblock]::Create($definition.Extent.Text))
    Import-Module PSScriptAnalyzer -ErrorAction Stop

    function New-MissingCommandFailure {
        param([string] $CommandName)

        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(
            [System.Management.Automation.Runspaces.InitialSessionState]::Create()
        )
        $pipeline = [powershell]::Create()
        try {
            $runspace.Open()
            $pipeline.Runspace = $runspace
            $null = $pipeline.AddCommand($CommandName)
            try {
                $null = $pipeline.Invoke()
            }
            catch {
                $_.Exception.InnerException | Should -BeOfType ([System.Management.Automation.CommandNotFoundException])
                $_.Exception.InnerException.CommandName | Should -BeExactly $CommandName
                return $_.Exception
            }
            throw [System.InvalidOperationException]::new('The empty runspace unexpectedly resolved the command.')
        }
        finally {
            $pipeline.Dispose()
            $runspace.Dispose()
        }
    }

    $script:missingGetCommand = New-MissingCommandFailure -CommandName 'Get-Command'
    $script:missingOtherCommand = New-MissingCommandFailure -CommandName 'Get-Item'
    $script:missingAnalyzer = New-MissingCommandFailure -CommandName 'Invoke-ScriptAnalyzer'
    $script:missingSimilarCommand = New-MissingCommandFailure -CommandName 'Get-CommandSuffix'
}

Describe 'Build analyzer retry' {
    BeforeEach {
        $script:previousLintAttempts = [Environment]::GetEnvironmentVariable('AVM_LINT_MAX_ATTEMPTS', 'Process')
        $env:AVM_LINT_MAX_ATTEMPTS = '3'
        $script:responses = [System.Collections.Generic.Queue[object]]::new()
        $script:analyzerParameters = @{
            Path = 'module'
            Recurse = $true
            Settings = 'analyzer-settings.psd1'
            CustomRulePath = 'custom-rules'
            RecurseCustomRulePath = $true
        }
        Mock Invoke-ScriptAnalyzer {
            $response = $script:responses.Dequeue()
            if ($response -is [System.Exception]) { throw $response }
            return $response
        }
        Mock Start-Sleep {}
        Mock Write-Information {}
    }

    AfterEach {
        $value = if ($null -eq $script:previousLintAttempts) { [NullString]::Value } else { $script:previousLintAttempts }
        [Environment]::SetEnvironmentVariable('AVM_LINT_MAX_ATTEMPTS', $value, 'Process')
    }

    It 'retries NRE then missing Get-Command within one attempt budget' {
        $script:responses.Enqueue([System.NullReferenceException]::new())
        $script:responses.Enqueue([System.Management.Automation.CmdletInvocationException]::new(
            'Analyzer invocation failed.', $script:missingGetCommand.InnerException
        ))
        $script:responses.Enqueue($null)

        Invoke-ScriptAnalyzerWithRetry -Params $script:analyzerParameters | Should -BeNullOrEmpty

        Should -Invoke Invoke-ScriptAnalyzer -Exactly 3 -ParameterFilter {
            $Path -ceq 'module' -and $Recurse -and $Settings -ceq 'analyzer-settings.psd1' -and
            $CustomRulePath -ceq 'custom-rules' -and $RecurseCustomRulePath
        }
        Should -Invoke Start-Sleep -Exactly 2
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Milliseconds -eq 500 }
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Milliseconds -eq 1000 }
        Should -Invoke Write-Information -Exactly 1 -ParameterFilter {
            $MessageData -like '*NullReferenceException*attempt 1/3*' -and $InformationAction -eq 'Continue'
        }
        Should -Invoke Write-Information -Exactly 1 -ParameterFilter {
            $MessageData -like '*Get-Command*attempt 2/3*' -and $InformationAction -eq 'Continue'
        }
    }

    It 'retries the real missing Get-Command failure with <Wrapper> wrapping' -TestCases @(
        @{ Wrapper = 'none' }
        @{ Wrapper = 'PowerShell method' }
        @{ Wrapper = 'analyzer cmdlet' }
        @{ Wrapper = 'nested invocation' }
    ) {
        param($Wrapper)
        $failure = switch ($Wrapper) {
            'none' { $script:missingGetCommand.InnerException }
            'PowerShell method' { $script:missingGetCommand }
            'analyzer cmdlet' {
                [System.Management.Automation.CmdletInvocationException]::new(
                    'Analyzer invocation failed.', $script:missingGetCommand.InnerException
                )
            }
            'nested invocation' {
                [System.Reflection.TargetInvocationException]::new($script:missingGetCommand)
            }
        }
        $script:responses.Enqueue($failure)
        $script:responses.Enqueue($null)

        Invoke-ScriptAnalyzerWithRetry -Params $script:analyzerParameters | Should -BeNullOrEmpty

        Should -Invoke Invoke-ScriptAnalyzer -Exactly 2
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Milliseconds -eq 500 }
    }

    It 'preserves existing NRE recognition for <Form> failures' -TestCases @(
        @{ Form = 'typed' }
        @{ Form = 'wrapped' }
        @{ Form = 'message' }
    ) {
        param($Form)
        $failure = switch ($Form) {
            'typed' { [System.NullReferenceException]::new() }
            'wrapped' {
                [System.Management.Automation.CmdletInvocationException]::new(
                    'Analyzer invocation failed.', [System.NullReferenceException]::new()
                )
            }
            'message' { [System.Exception]::new('Object reference not set to an instance of an object.') }
        }
        $script:responses.Enqueue($failure)
        $script:responses.Enqueue($null)

        Invoke-ScriptAnalyzerWithRetry -Params $script:analyzerParameters | Should -BeNullOrEmpty

        Should -Invoke Invoke-ScriptAnalyzer -Exactly 2
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Milliseconds -eq 500 }
    }

    It 'preserves the original final <Failure> exception after the default eight attempts' -TestCases @(
        @{ Failure = 'NRE' }
        @{ Failure = 'missing Get-Command' }
    ) {
        param($Failure)
        [Environment]::SetEnvironmentVariable('AVM_LINT_MAX_ATTEMPTS', [NullString]::Value, 'Process')
        $firstFailure = if ($Failure -ceq 'NRE') { [System.NullReferenceException]::new() } else { $script:missingGetCommand.InnerException }
        $finalFailure = if ($Failure -ceq 'NRE') { [System.NullReferenceException]::new('Final NRE.') } else { $script:missingGetCommand }
        foreach ($attempt in 1..7) { $script:responses.Enqueue($firstFailure) }
        $script:responses.Enqueue($finalFailure)

        $caught = { Invoke-ScriptAnalyzerWithRetry -Params $script:analyzerParameters } | Should -Throw -PassThru

        [object]::ReferenceEquals($caught.Exception, $finalFailure) | Should -BeTrue
        Should -Invoke Invoke-ScriptAnalyzer -Exactly 8
        Should -Invoke Start-Sleep -Exactly 7
        Should -Invoke Write-Information -Exactly 7
        foreach ($delay in 500, 1000, 1500, 2000, 2500, 3000, 3500) {
            Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Milliseconds -eq $delay }
        }
    }

    It 'does not reset the configured attempt limit when the exception changes' {
        $env:AVM_LINT_MAX_ATTEMPTS = '2'
        $script:responses.Enqueue([System.NullReferenceException]::new())
        $script:responses.Enqueue($script:missingGetCommand)
        $script:responses.Enqueue($null)

        $caught = { Invoke-ScriptAnalyzerWithRetry -Params $script:analyzerParameters } | Should -Throw -PassThru

        [object]::ReferenceEquals($caught.Exception, $script:missingGetCommand) | Should -BeTrue
        Should -Invoke Invoke-ScriptAnalyzer -Exactly 2
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Milliseconds -eq 500 }
        Should -Invoke Write-Information -Exactly 1
    }

    It 'makes only one attempt when the configured limit is <Limit>' -TestCases @(
        @{ Limit = '1' }
        @{ Limit = '0' }
        @{ Limit = '-1' }
    ) {
        param($Limit)
        $env:AVM_LINT_MAX_ATTEMPTS = $Limit
        $script:responses.Enqueue($script:missingGetCommand)

        $caught = { Invoke-ScriptAnalyzerWithRetry -Params $script:analyzerParameters } | Should -Throw -PassThru

        [object]::ReferenceEquals($caught.Exception, $script:missingGetCommand) | Should -BeTrue
        Should -Invoke Invoke-ScriptAnalyzer -Exactly 1
        Should -Invoke Start-Sleep -Exactly 0
        Should -Invoke Write-Information -Exactly 0
    }

    It 'immediately propagates unrelated failure: <Case>' -TestCases @(
        @{ Case = 'another missing command' }
        @{ Case = 'missing analyzer' }
        @{ Case = 'similar command name' }
        @{ Case = 'command exception with only matching text' }
        @{ Case = 'runtime exception with only matching text' }
        @{ Case = 'generic exception with only matching text' }
        @{ Case = 'message mentioning Get-Command' }
        @{ Case = 'wrapped unrelated exception' }
    ) {
        param($Case)
        $failure = switch ($Case) {
            'another missing command' { $script:missingOtherCommand }
            'missing analyzer' { $script:missingAnalyzer }
            'similar command name' { $script:missingSimilarCommand }
            'command exception with only matching text' {
                [System.Management.Automation.CommandNotFoundException]::new($script:missingGetCommand.InnerException.Message)
            }
            'runtime exception with only matching text' {
                [System.Management.Automation.RuntimeException]::new($script:missingGetCommand.InnerException.Message)
            }
            'generic exception with only matching text' {
                [System.InvalidOperationException]::new($script:missingGetCommand.InnerException.Message)
            }
            'message mentioning Get-Command' { [System.IO.IOException]::new('Get-Command could not read a configuration file.') }
            'wrapped unrelated exception' {
                [System.Management.Automation.CmdletInvocationException]::new(
                    'Analyzer invocation failed.', $script:missingOtherCommand.InnerException
                )
            }
        }
        $script:responses.Enqueue($failure)
        $script:responses.Enqueue($null)

        $caught = { Invoke-ScriptAnalyzerWithRetry -Params $script:analyzerParameters } | Should -Throw -PassThru

        [object]::ReferenceEquals($caught.Exception, $failure) | Should -BeTrue
        Should -Invoke Invoke-ScriptAnalyzer -Exactly 1
        Should -Invoke Start-Sleep -Exactly 0
        Should -Invoke Write-Information -Exactly 0
    }

    It 'returns genuine <Severity> findings unchanged without retries' -TestCases @(
        @{ Severity = 'Information' }
        @{ Severity = 'Warning' }
        @{ Severity = 'Error' }
        @{ Severity = 'ParseError' }
    ) {
        param($Severity)
        $diagnostic = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]::new(
            $script:missingGetCommand.InnerException.Message, $null, 'TestRule',
            [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]$Severity,
            'module.ps1', $null, $null
        )
        $script:responses.Enqueue($diagnostic)

        $result = @(Invoke-ScriptAnalyzerWithRetry -Params $script:analyzerParameters)

        $result | Should -HaveCount 1
        [object]::ReferenceEquals($result[0], $diagnostic) | Should -BeTrue
        Should -Invoke Invoke-ScriptAnalyzer -Exactly 1
        Should -Invoke Start-Sleep -Exactly 0
        Should -Invoke Write-Information -Exactly 0
    }

    It 'stops immediately when an unrelated error follows a retryable failure' {
        $script:responses.Enqueue($script:missingGetCommand)
        $script:responses.Enqueue($script:missingOtherCommand)
        $script:responses.Enqueue($null)

        $caught = { Invoke-ScriptAnalyzerWithRetry -Params $script:analyzerParameters } | Should -Throw -PassThru

        [object]::ReferenceEquals($caught.Exception, $script:missingOtherCommand) | Should -BeTrue
        Should -Invoke Invoke-ScriptAnalyzer -Exactly 2
        Should -Invoke Start-Sleep -Exactly 1
        Should -Invoke Write-Information -Exactly 1
    }

    It 'returns findings after a transient failure instead of retrying or suppressing them' {
        $diagnostics = @(
            [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]::new(
                'Object reference not set to an instance of an object.', $null, 'FirstRule', 'Error', 'first.ps1', $null, $null
            )
            [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]::new(
                $script:missingGetCommand.InnerException.Message, $null, 'SecondRule', 'Warning', 'second.ps1', $null, $null
            )
        )
        $script:responses.Enqueue($script:missingGetCommand)
        $script:responses.Enqueue($diagnostics)

        $result = @(Invoke-ScriptAnalyzerWithRetry -Params $script:analyzerParameters)

        $result | Should -HaveCount 2
        [object]::ReferenceEquals($result[0], $diagnostics[0]) | Should -BeTrue
        [object]::ReferenceEquals($result[1], $diagnostics[1]) | Should -BeTrue
        Should -Invoke Invoke-ScriptAnalyzer -Exactly 2
        Should -Invoke Start-Sleep -Exactly 1
    }
}
