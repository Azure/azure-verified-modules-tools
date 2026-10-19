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
    foreach ($functionName in 'script:Invoke-ScriptAnalyzerSerial', 'script:Invoke-ScriptAnalyzerWithRetry') {
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $functionName
        }, $true)
        $definition | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($definition.Extent.Text))
    }
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

    function New-AnalyzerDiagnostic {
        param([string] $Rule, [string] $Severity = 'Warning')
        [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]::new(
            'diagnostic', $null, $Rule,
            [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]$Severity,
            'fixture.ps1', $null, $null
        )
    }
}

Describe 'Build analyzer serial partitions' {
    BeforeEach {
        $script:previousLintAttempts = [Environment]::GetEnvironmentVariable('AVM_LINT_MAX_ATTEMPTS', 'Process')
        $env:AVM_LINT_MAX_ATTEMPTS = '2'
        $script:partitionParameters = @{
            Path = 'module'
            Recurse = $true
            Settings = 'analyzer-settings.psd1'
            CustomRulePath = 'custom-rules'
            RecurseCustomRulePath = $true
        }
        Mock Get-ScriptAnalyzerRule {
            [pscustomobject]@{ RuleName = 'PSFirst' }
            [pscustomobject]@{ RuleName = 'PSSecond' }
        }
        Mock Invoke-ScriptAnalyzer {}
        Mock Start-Sleep {}
        Mock Write-Information {}
    }

    AfterEach {
        $value = if ($null -eq $script:previousLintAttempts) { [NullString]::Value } else { $script:previousLintAttempts }
        [Environment]::SetEnvironmentVariable('AVM_LINT_MAX_ATTEMPTS', $value, 'Process')
    }

    It 'partitions discovered builtins and unchanged custom discovery with full original arguments' {
        $before = $script:partitionParameters | ConvertTo-Json -Compress

        Invoke-ScriptAnalyzerWithRetry -Params $script:partitionParameters | Should -BeNullOrEmpty

        Should -Invoke Invoke-ScriptAnalyzer -Exactly 3 -ParameterFilter {
            $Path -ceq 'module' -and $Recurse -and $Settings -ceq 'analyzer-settings.psd1' -and
            $CustomRulePath -ceq 'custom-rules' -and $RecurseCustomRulePath
        }
        foreach ($rule in 'PSFirst', 'PSSecond') {
            Should -Invoke Invoke-ScriptAnalyzer -Exactly 1 -ParameterFilter {
                $IncludeRule -and @($IncludeRule).Count -eq 1 -and $IncludeRule[0] -ceq $rule
            }
        }
        Should -Invoke Invoke-ScriptAnalyzer -Exactly 1 -ParameterFilter {
            -not $IncludeRule -and @($ExcludeRule).Count -eq 2 -and
            'PSFirst' -in $ExcludeRule -and 'PSSecond' -in $ExcludeRule
        }
        ($script:partitionParameters | ConvertTo-Json -Compress) | Should -BeExactly $before
    }

    It 'retains parser diagnostics once by actual severity without deduplicating other findings' {
        $script:parserDiagnostic = New-AnalyzerDiagnostic -Rule 'MissingEndCurlyBrace' -Severity ParseError
        $script:ordinaryDiagnostic = New-AnalyzerDiagnostic -Rule 'ParseError' -Severity Warning
        Mock Invoke-ScriptAnalyzer {
            $script:parserDiagnostic
            $script:ordinaryDiagnostic
            $script:ordinaryDiagnostic
        }

        $result = @(Invoke-ScriptAnalyzerWithRetry -Params $script:partitionParameters)

        @($result | Where-Object Severity -eq ParseError) | Should -HaveCount 1
        @($result | Where-Object Severity -eq Warning) | Should -HaveCount 6
        [object]::ReferenceEquals($result[0], $script:parserDiagnostic) | Should -BeTrue
        @($result | Where-Object { [object]::ReferenceEquals($_, $script:ordinaryDiagnostic) }) | Should -HaveCount 6
    }

    It 'preserves original exclusions and does not need a custom partition without custom arguments' {
        $script:partitionParameters.Remove('CustomRulePath')
        $script:partitionParameters.Remove('RecurseCustomRulePath')
        $script:partitionParameters.ExcludeRule = @('PSOriginalExclusion')

        Invoke-ScriptAnalyzerWithRetry -Params $script:partitionParameters | Should -BeNullOrEmpty

        Should -Invoke Invoke-ScriptAnalyzer -Exactly 2 -ParameterFilter {
            $ExcludeRule.Count -eq 1 -and $ExcludeRule[0] -ceq 'PSOriginalExclusion'
        }
    }

    It 'restarts the whole pass within the original budget without emitting partial findings' {
        $script:partitionFailure = [System.NullReferenceException]::new('Final partition failure.')
        $script:partialDiagnostic = New-AnalyzerDiagnostic -Rule PSFirst
        Mock Invoke-ScriptAnalyzer {
            if ($IncludeRule -contains 'PSSecond') { throw $script:partitionFailure }
            $script:partialDiagnostic
        }

        $emitted = [System.Collections.Generic.List[object]]::new()
        $caught = { Invoke-ScriptAnalyzerWithRetry -Params $script:partitionParameters | ForEach-Object { $emitted.Add($_) } } |
            Should -Throw -PassThru

        [object]::ReferenceEquals($caught.Exception, $script:partitionFailure) | Should -BeTrue
        $emitted.Count | Should -Be 0
        Should -Invoke Invoke-ScriptAnalyzer -Exactly 4
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Milliseconds -eq 500 }
    }

    It 'fails explicitly when builtin discovery produces no rules' {
        Mock Get-ScriptAnalyzerRule {}

        { Invoke-ScriptAnalyzerWithRetry -Params $script:partitionParameters } | Should -Throw '*no built-in rules*'

        Should -Invoke Invoke-ScriptAnalyzer -Exactly 0
        Should -Invoke Start-Sleep -Exactly 0
    }

    It 'discards failed-attempt findings before returning a later complete pass' {
        $script:firstPartitionCalls = 0
        Mock Invoke-ScriptAnalyzer {
            if ($IncludeRule -contains 'PSFirst') {
                $script:firstPartitionCalls++
                New-AnalyzerDiagnostic -Rule "Attempt$script:firstPartitionCalls"
            }
            elseif ($IncludeRule -contains 'PSSecond') {
                if ($script:firstPartitionCalls -eq 1) { throw [System.NullReferenceException]::new('Transient failure.') }
                New-AnalyzerDiagnostic -Rule PSSecond
            }
        }

        $result = @(Invoke-ScriptAnalyzerWithRetry -Params $script:partitionParameters)

        $result | Should -HaveCount 2
        $result.RuleName | Should -Be @('Attempt2', 'PSSecond')
        Should -Invoke Invoke-ScriptAnalyzer -Exactly 5
        Should -Invoke Start-Sleep -Exactly 1
    }

    It 'preserves additional custom-partition exclusions and propagates unrelated errors immediately' {
        $script:partitionParameters.ExcludeRule = @('OriginalExclusion')
        $script:customFailure = [System.InvalidOperationException]::new('Custom rule failure.')
        Mock Invoke-ScriptAnalyzer {
            if (-not $IncludeRule) { throw $script:customFailure }
            New-AnalyzerDiagnostic -Rule PSFirst
        }
        $emitted = [System.Collections.Generic.List[object]]::new()

        $caught = { Invoke-ScriptAnalyzerWithRetry -Params $script:partitionParameters | ForEach-Object { $emitted.Add($_) } } |
            Should -Throw -PassThru

        [object]::ReferenceEquals($caught.Exception, $script:customFailure) | Should -BeTrue
        $emitted.Count | Should -Be 0
        Should -Invoke Invoke-ScriptAnalyzer -Exactly 1 -ParameterFilter {
            -not $IncludeRule -and @($ExcludeRule).Count -eq 3 -and
            'OriginalExclusion' -in $ExcludeRule -and 'PSFirst' -in $ExcludeRule -and 'PSSecond' -in $ExcludeRule
        }
        Should -Invoke Start-Sleep -Exactly 0
    }
}

Describe 'Build analyzer real parser equivalence' {
    BeforeAll {
        $script:realParameters = @{
            Path = $TestDrive
            Recurse = $true
            Settings = Join-Path $repoRoot 'src' 'Avm.Authoring' 'Resources' 'PSScriptAnalyzerSettings.psd1'
            CustomRulePath = Join-Path $repoRoot 'src' 'Avm.Authoring' 'Resources' 'CustomRules'
            RecurseCustomRulePath = $true
            Severity = @('Error', 'Warning', 'Information', 'ParseError')
        }
        Set-Content -LiteralPath (Join-Path $TestDrive 'Broken.ps1') -Value 'function Get-Broken {'
        Set-Content -LiteralPath (Join-Path $TestDrive 'Findings.ps1') -Value @'
function get-AnalyzerFixture {
param([switch]$Enabled = $true)
$unused = ConvertTo-SecureString 'fixture' -AsPlainText -Force
write-host 'fixture'
}
function Get-AnalyzerOutputFixture {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 42
}
'@
    }

    It 'matches real parser identity and the complete finding multiset without changing configured severities' {
        $baselineErrors = @()
        $baseline = @(Invoke-ScriptAnalyzer @script:realParameters -ErrorVariable baselineErrors)
        $baselineErrors | Should -BeNullOrEmpty
        $analyzerVersion = (Get-Module -Name PSScriptAnalyzer).Version.ToString()
        $baselineSeverities = ($baseline.Severity | Sort-Object -Unique) -join ', '
        $casingSeverities = ($baseline | Where-Object RuleName -eq PSUseCorrectCasing | Select-Object -ExpandProperty Severity -Unique) -join ', '
        Write-Information "Real analyzer fixture: PSScriptAnalyzer $analyzerVersion; severities $baselineSeverities; casing [$casingSeverities]." -InformationAction Continue
        $baselineParser = @($baseline | Where-Object Severity -eq ParseError)
        $baselineParser | Should -HaveCount 1
        $baselineParser[0] | Should -BeOfType ([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord])
        $baselineParser[0].RuleName | Should -BeExactly 'MissingEndCurlyBrace'
        $baselineParser[0].Extent.StartLineNumber | Should -Be 1
        @($baseline | Where-Object { $_.RuleName -eq 'PSUseOutputTypeCorrectly' -and $_.Severity -eq 'Information' }) |
            Should -HaveCount 1
        foreach ($severity in 'Error', 'Warning', 'Information') {
            @($baseline | Where-Object Severity -eq $severity).Count |
                Should -BeGreaterThan 0 -Because "the real fixture must include $severity findings with PSScriptAnalyzer $analyzerVersion"
        }

        $serial = @(Invoke-ScriptAnalyzerWithRetry -Params $script:realParameters 2>&1)
        @($serial | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | Should -BeNullOrEmpty
        @($serial | Where-Object Severity -eq ParseError) | Should -HaveCount 1
        $keys = {
            [pscustomobject]@{
                Type = $_.GetType().FullName
                Rule = $_.RuleName
                Severity = $_.Severity.ToString()
                Message = $_.Message
                File = $_.ScriptPath
                Extent = $_.Extent | Select-Object StartLineNumber, StartColumnNumber, EndLineNumber, EndColumnNumber, Text
                Suppression = $_.RuleSuppressionID
                Corrections = $_.SuggestedCorrections
            } | ConvertTo-Json -Depth 10 -Compress
        }
        $actual = @($serial | ForEach-Object $keys | Sort-Object)
        $expected = @($baseline | ForEach-Object $keys | Sort-Object)
        $actual | Should -HaveCount $expected.Count
        Compare-Object $expected $actual | Should -BeNullOrEmpty
    }

    It 'retains effective custom rules only when the original public arguments already discover them' {
        $parameters = $script:realParameters.Clone()
        $parameters.Path = Join-Path $TestDrive 'CustomFinding.ps1'
        Set-Content -LiteralPath $parameters.Path -Value "throw 'fixture'"
        $parameters.CustomRulePath = Join-Path $script:realParameters.CustomRulePath 'AvmAvoidStringThrow.psm1'
        $baseline = @(Invoke-ScriptAnalyzer @parameters)
        @($baseline | Where-Object RuleName -Like '*AvmAvoidStringThrow*') | Should -HaveCount 1

        $serial = @(Invoke-ScriptAnalyzerWithRetry -Params $parameters)

        @($serial | Where-Object RuleName -Like '*AvmAvoidStringThrow*') | Should -HaveCount 1
        $serial | Should -HaveCount $baseline.Count
        Compare-Object @($baseline | ForEach-Object { "$($_.RuleName)|$($_.Severity)|$($_.Message)" } | Sort-Object) @(
            $serial | ForEach-Object { "$($_.RuleName)|$($_.Severity)|$($_.Message)" } | Sort-Object
        ) | Should -BeNullOrEmpty
    }
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
        Mock Invoke-ScriptAnalyzerSerial {
            param([hashtable] $Params)
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

        Should -Invoke Invoke-ScriptAnalyzerSerial -Exactly 3 -ParameterFilter {
            $Params.Path -ceq 'module' -and $Params.Recurse -and $Params.Settings -ceq 'analyzer-settings.psd1' -and
            $Params.CustomRulePath -ceq 'custom-rules' -and $Params.RecurseCustomRulePath
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

        Should -Invoke Invoke-ScriptAnalyzerSerial -Exactly 2
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

        Should -Invoke Invoke-ScriptAnalyzerSerial -Exactly 2
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
        Should -Invoke Invoke-ScriptAnalyzerSerial -Exactly 8
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
        Should -Invoke Invoke-ScriptAnalyzerSerial -Exactly 2
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
        Should -Invoke Invoke-ScriptAnalyzerSerial -Exactly 1
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
        Should -Invoke Invoke-ScriptAnalyzerSerial -Exactly 1
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
        Should -Invoke Invoke-ScriptAnalyzerSerial -Exactly 1
        Should -Invoke Start-Sleep -Exactly 0
        Should -Invoke Write-Information -Exactly 0
    }

    It 'stops immediately when an unrelated error follows a retryable failure' {
        $script:responses.Enqueue($script:missingGetCommand)
        $script:responses.Enqueue($script:missingOtherCommand)
        $script:responses.Enqueue($null)

        $caught = { Invoke-ScriptAnalyzerWithRetry -Params $script:analyzerParameters } | Should -Throw -PassThru

        [object]::ReferenceEquals($caught.Exception, $script:missingOtherCommand) | Should -BeTrue
        Should -Invoke Invoke-ScriptAnalyzerSerial -Exactly 2
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
        Should -Invoke Invoke-ScriptAnalyzerSerial -Exactly 2
        Should -Invoke Start-Sleep -Exactly 1
    }
}
