#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Set-StrictMode -Version 3.0

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    $script:manifestPath = Join-Path $script:moduleRoot 'Avm.Authoring.psd1'
    Import-Module $script:manifestPath -Force

    function script:New-AvmChildProcessStartInfo {
        param(
            [Parameter(Mandatory)]
            [string[]] $ArgumentList,

            [switch] $RedirectStandardInput
        )

        $pwsh = Get-Command -Name pwsh -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwsh.Source
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $RedirectStandardInput
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        foreach ($argument in $ArgumentList) {
            [void] $startInfo.ArgumentList.Add($argument)
        }

        foreach ($name in @(
                'CI',
                'GITHUB_ACTIONS',
                'GITHUB_ENV',
                'GITHUB_OUTPUT',
                'GITHUB_STEP_SUMMARY',
                'GITHUB_WORKSPACE',
                'RUNNER_DEBUG'
            )) {
            [void] $startInfo.Environment.Remove($name)
        }

        return $startInfo
    }

    function script:Invoke-AvmChildProcess {
        param(
            [Parameter(Mandatory)]
            [System.Diagnostics.ProcessStartInfo] $StartInfo,

            [string] $StandardInput,

            [switch] $StripStdinHostControlSequences
        )

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $StartInfo
        try {
            [void] $process.Start()
            if ($StartInfo.RedirectStandardInput) {
                $process.StandardInput.Write($StandardInput)
                $process.StandardInput.Close()
            }

            $stdOut = $process.StandardOutput.ReadToEnd()
            $stdErr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()

            $output = @($stdOut.Trim(), $stdErr.Trim()) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $outputText = (($output -join "`n").Replace("`r", ''))
            if ($StripStdinHostControlSequences) {
                $outputText = ($outputText -replace "$([char]27)\[\?1[hl]", '').Trim()
            }
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output   = $outputText
            }
        }
        finally {
            $process.Dispose()
        }
    }

    # Runs a fresh child pwsh that imports the module, replaces the verb registry
    # with a single fake verb whose cmdlet returns the supplied result object, then
    # invokes 'avm spec-verb'. Each child is isolated, so the observed process exit
    # mirrors how a `run:` step with `shell: pwsh` reacts in GitHub Actions.
    function script:Invoke-AvmChildVerb {
        param(
            [Parameter(Mandatory)][string] $Body,
            [ValidateSet('File', 'Command')][string] $Mode = 'File',
            [switch] $CaptureTypedError,
            [switch] $RejectOutdatedModule,
            [switch] $RunnerDebug,
            [string] $Invocation
        )

        $manifest = $script:manifestPath

        if ($CaptureTypedError) {
            $invoke = @'
try {
    avm spec-verb | Out-Null
    'NO-THROW'
} catch {
    $e = $_.Exception
    '{0}|{1}|{2}' -f $e.GetType().Name, $e.Verb, $e.CommandStatus
}
'@
        } elseif ($Invocation) {
            $invoke = $Invocation
        } else {
            $invoke = 'avm spec-verb | Out-Null'
        }

        $guardOverride = if ($RejectOutdatedModule) {
            @'
function script:Test-AvmModuleVersion {
    throw [AvmModuleVersionException]::new(
        [version]'0.16.0',
        [version]'0.17.1',
        @(
            'Installed version: 0.16.0'
            'Latest version: 0.17.1'
            ''
            'Update and reload the module:'
            '  Update-PSResource -Name Avm.Authoring -Scope CurrentUser'
            '  Import-Module Avm.Authoring -Force'
        ) -join "`n")
}
'@
        }
        else {
            ''
        }

        $scriptText = @"
`$ErrorActionPreference = 'Stop'
`$PSStyle.OutputRendering = 'PlainText'
Import-Module '$manifest' -Force
`$module = Get-Module Avm.Authoring
& `$module {
    function script:Get-AvmVerbRegistry {
        [pscustomobject]@{ Path = [string[]]@('spec-verb'); Cmdlet = 'Invoke-AvmSpecVerb'; Summary = 'test verb' }
    }
    function script:Invoke-AvmSpecVerb { $Body }
    $guardOverride
}
$invoke
"@

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-f02-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Value $scriptText -Encoding utf8
        try {
            $arguments = if ($Mode -eq 'File') {
                @('-NoProfile', '-File', $tmp)
            }
            else {
                @('-NoProfile', '-Command', ". '$tmp'")
            }
            $startInfo = New-AvmChildProcessStartInfo -ArgumentList $arguments
            if ($RunnerDebug) {
                $startInfo.Environment['RUNNER_DEBUG'] = '1'
            }
            Invoke-AvmChildProcess -StartInfo $startInfo
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    function script:Invoke-AvmChildPrCheck {
        param(
            [Parameter(Mandatory)]
            [string] $Body,

            [string] $Invocation = 'avm pr-check | Out-Null'
        )

        $manifest = $script:manifestPath
        $scriptText = @"
`$ErrorActionPreference = 'Stop'
`$PSStyle.OutputRendering = 'PlainText'
Import-Module '$manifest' -Force
`$module = Get-Module Avm.Authoring
& `$module {
    function script:Get-AvmVerbRegistry {
        [pscustomobject]@{ Path = [string[]]@('pr-check'); Cmdlet = 'Invoke-AvmPrCheck'; Summary = 'test PR check' }
    }
    function script:Invoke-AvmPrCheck { $Body }
}
$Invocation
"@
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-pr-check-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Value $scriptText -Encoding utf8
        try {
            $startInfo = New-AvmChildProcessStartInfo -ArgumentList @('-NoProfile', '-File', $tmp)
            Invoke-AvmChildProcess -StartInfo $startInfo
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-Avm array dispatch' {
    It 'preserves <Case> without consuming the following parameter' -ForEach @(
        @{ Case = 'array expressions'; Invocation = "avm spec-verb -Names @('lint', 'check policy') -Label kept"; Count = 2; Values = 'lint|check policy' }
        @{ Case = 'comma-separated arrays'; Invocation = "avm spec-verb --names 'lint','check policy' --label kept"; Count = 2; Values = 'lint|check policy' }
        @{ Case = 'array variables'; Invocation = '$names = @(''lint'', ''check policy''); avm spec-verb -Names $names -Label kept'; Count = 2; Values = 'lint|check policy' }
        @{ Case = 'scalar values'; Invocation = "avm spec-verb -Names 'check policy' -Label kept"; Count = 1; Values = 'check policy' }
        @{ Case = 'one-item arrays'; Invocation = "avm spec-verb -Names @('check policy') -Label kept"; Count = 1; Values = 'check policy' }
        @{ Case = 'empty arrays'; Invocation = 'avm spec-verb -Names @() -Label kept'; Count = 0; Values = '' }
        @{ Case = 'pass-through tokens inside arrays'; Invocation = "avm spec-verb -Names @('--passthru') -Label kept"; Count = 1; Values = '--passthru' }
    ) {
        $body = @'
[CmdletBinding()]
param([string[]] $Names, [string] $Label)
'COUNT={0};NAMES={1};LABEL={2}' -f $Names.Count, ($Names -join '|'), $Label
'@
        $result = Invoke-AvmChildVerb -Body $body -Invocation $Invocation
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match ([regex]::Escape("COUNT=$Count;NAMES=$Values;LABEL=kept"))
    }
}

Describe 'Invoke-Avm verbose dispatch' {
    It 'enables verbose output when GitHub Actions debug logging is active' {
        $body = "Write-Verbose 'runner-debug-marker'; [pscustomobject]@{ Status = 'pass' }"

        $quiet = Invoke-AvmChildVerb -Mode File -Body $body
        $debug = Invoke-AvmChildVerb -Mode File -Body $body -RunnerDebug

        $quiet.Output | Should -Not -Match 'runner-debug-marker'
        $debug.Output | Should -Match 'runner-debug-marker'
    }
}

Describe 'Invoke-Avm dispatch failure semantics (F02)' {
    It 'exits non-zero via pwsh -File when a verb reports fail' {
        (Invoke-AvmChildVerb -Mode File -Body "[pscustomobject]@{ Status = 'fail' }").ExitCode |
            Should -Not -Be 0
    }

    It 'exits non-zero via pwsh -Command when a verb reports fail' {
        # Dot-sourcing under -Command is how a `run:` step with `shell: pwsh` runs.
        (Invoke-AvmChildVerb -Mode Command -Body "[pscustomobject]@{ Status = 'fail' }").ExitCode |
            Should -Not -Be 0
    }

    It 'exits non-zero when a verb reports error' {
        (Invoke-AvmChildVerb -Mode File -Body "[pscustomobject]@{ Status = 'error' }").ExitCode |
            Should -Not -Be 0
    }

    It 'rejects an outdated module with upgrade guidance before running the verb' {
        $result = Invoke-AvmChildVerb `
            -Mode File `
            -Body "[pscustomobject]@{ Status = 'pass' }" `
            -RejectOutdatedModule

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match "Avm\.Authoring 0\.16\.0 is outdated\. Version 0\.17\.1 is required to run 'avm spec-verb'\."
        $result.Output | Should -Match "Update-PSResource -Name Avm\.Authoring -Scope CurrentUser"
        $result.Output | Should -Not -Match 'NotInstalled:'
        $result.Output | Should -Not -Match 'avm spec-verb: pass'
        $result.Output | Should -Not -Match '\.ps1:\d+'
    }

    It 'exits zero when a verb reports pass' {
        (Invoke-AvmChildVerb -Mode File -Body "[pscustomobject]@{ Status = 'pass' }").ExitCode |
            Should -Be 0
    }

    It 'exits zero for a read verb that has no Status property' {
        $manifest = $script:manifestPath
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-f02-ver-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Value "Import-Module '$manifest' -Force; avm version | Out-Null" -Encoding utf8
        try {
            & pwsh -NoProfile -File $tmp | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'makes a failed PR check nonzero while preserving its structured result for machine callers' {
        $body = @'
[pscustomobject]@{
    Status = 'fail'
    Steps = @(
        [pscustomobject]@{ Step = 'check policy'; Status = 'fail'; Error = 'Required policy failed.' }
        [pscustomobject]@{ Step = 'docs'; Status = 'pass'; Error = $null }
    )
}
'@
        $human = Invoke-AvmChildPrCheck -Body $body
        $machine = Invoke-AvmChildPrCheck -Body $body -Invocation @'
try {
    avm pr-check --passthru | Out-Null
    'NO-THROW'
}
catch {
    $_.Exception.Result | ConvertTo-Json -Depth 10 -Compress
}
'@

        $human.ExitCode | Should -Not -Be 0
        $human.Output | Should -Match 'avm pr-check: fail'
        $machine.ExitCode | Should -Be 0
        $machine.Output | Should -Not -Match 'NO-THROW'
        $result = @($machine.Output -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } |
                Select-Object -Last 1) | ConvertFrom-Json
        $result.Status | Should -BeExactly 'fail'
        $result.Steps[0].Step | Should -BeExactly 'check policy'
        $result.Steps[0].Status | Should -BeExactly 'fail'
        $result.Steps[1].Status | Should -BeExactly 'pass'
    }
}

Describe 'Invoke-Avm typed failure (F02)' {
    It 'throws AvmCommandException carrying the failed verb and status' {
        $result = Invoke-AvmChildVerb -Mode File -CaptureTypedError -Body "[pscustomobject]@{ Status = 'fail' }"
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'AvmCommandException\|spec-verb\|fail$'
    }

    It 'includes the first issue in the command exception message' {
        $body = @"
[pscustomobject]@{
    Status = 'fail'
    Issues = @([pscustomobject]@{
        Severity = 'error'; File = 'main.tf'; Line = 7; Column = 3
        Code = 'avm.test'; Message = 'diagnostic detail'
    })
}
"@
        $result = Invoke-AvmChildVerb -Mode File -CaptureTypedError -Body $body
        $result.Output | Should -Match 'diagnostic detail'
    }
}

Describe 'Invoke-Avm presented lint terminal diagnostics' {
    BeforeAll {
        $script:presentedLintBody = @'
$env:GITHUB_ACTIONS = 'true'
$issue = [pscustomobject]@{
    Severity = 'warning'; File = 'examples\default\variables.tf'; Line = 11; Column = 3
    Code = 'terraform_unused_declarations'; Message = 'unused location'
}
Write-AvmLog '[terraform_unused_declarations] unused location' -Level Error -File $issue.File -Line $issue.Line -Column $issue.Column
Register-AvmPresentedIssue -Issue $issue
$lintResult = [pscustomobject]@{ Status = 'fail'; Issues = @($issue) }
'@
    }

    It 'does not repeat an inline blocker for <Shape> under pwsh -<Mode>' -ForEach @(
        @{ Shape = 'standalone lint'; Mode = 'File'; ResultExpression = '$lintResult' }
        @{ Shape = 'standalone lint'; Mode = 'Command'; ResultExpression = '$lintResult' }
        @{ Shape = 'composed lint'; Mode = 'File'; ResultExpression = "[pscustomobject]@{ Status = 'fail'; Steps = @([pscustomobject]@{ Step = 'lint'; Status = 'fail'; Error = `$null; Result = `$lintResult }) }" }
        @{ Shape = 'composed lint'; Mode = 'Command'; ResultExpression = "[pscustomobject]@{ Status = 'fail'; Steps = @([pscustomobject]@{ Step = 'lint'; Status = 'fail'; Error = `$null; Result = `$lintResult }) }" }
    ) {
        $body = $script:presentedLintBody + "`n" + '$script:expectedDispatchResult = ' + $ResultExpression + "`n" + '$script:expectedDispatchResult'
        $result = Invoke-AvmChildVerb -Mode $Mode -Body $body

        $result.ExitCode | Should -Not -Be 0
        $annotations = @($result.Output -split "`n" | Where-Object { $_ -like '::error*' })
        $annotations.Count | Should -Be 1
        $annotations[0] | Should -BeExactly '::error file=examples/default/variables.tf,line=11,col=3::[terraform_unused_declarations] unused location'
        $result.Output | Should -Match 'avm spec-verb: fail'
        $result.Output | Should -Not -Match 'Assert-AvmCommandSuccess\.ps1:\d+'

        $capture = @'
try {
    avm spec-verb | Out-Null
    'NO-THROW'
} catch {
    $exception = $_.Exception
    $expected = & $module { $script:expectedDispatchResult }
    'CAUGHT|{0}|{1}|{2}|{3}|{4}' -f $exception.GetType().Name, $exception.Verb, $exception.CommandStatus, $exception.Code, [object]::ReferenceEquals($expected, $exception.Result)
    'RESULT|' + ($exception.Result | ConvertTo-Json -Depth 10 -Compress)
    'MESSAGE|' + $exception.Message
}
'@
        $caught = Invoke-AvmChildVerb -Mode $Mode -Body $body -Invocation $capture
        $caught.ExitCode | Should -Be 0
        $caught.Output | Should -Match 'CAUGHT\|AvmCommandException\|spec-verb\|fail\|AVM1040\|True'
        $caught.Output | Should -Match "MESSAGE\|avm spec-verb reported Status 'fail'\."
        $caught.Output | Should -Match 'unused location'
        $caught.Output | Should -Not -Match 'NO-THROW'
        @($caught.Output -split "`n" | Where-Object { $_ -like '::error*' }).Count | Should -Be 1
        $jsonLine = @($caught.Output -split "`n" | Where-Object { $_ -like 'RESULT|*' })
        $jsonLine.Count | Should -Be 1
        $original = $jsonLine[0].Substring('RESULT|'.Length) | ConvertFrom-Json
        $original.Status | Should -BeExactly 'fail'
        $originalIssue = if ($Shape -eq 'standalone lint') { $original.Issues[0] } else { $original.Steps[0].Result.Issues[0] }
        $originalIssue.Severity | Should -BeExactly 'warning'
        $originalIssue.Code | Should -BeExactly 'terraform_unused_declarations'
        $originalIssue.Message | Should -BeExactly 'unused location'
    }

    It 'retains a distinct <FailureKind> after an inline lint blocker' -ForEach @(
        @{ FailureKind = 'issue'; ErrorExpression = '$null'; ResultExpression = "[pscustomobject]@{ Issues = @([pscustomobject]@{ Severity = 'error'; File = 'main.tf'; Line = 29; Column = 4; Message = 'distinct policy failure' }) }"; Annotation = "::error file=main.tf,line=29,col=4::Step 'check policy': error main.tf:29:4 distinct policy failure" }
        @{ FailureKind = 'step error'; ErrorExpression = "'distinct policy failure'"; ResultExpression = '$lintResult'; Annotation = "::error::Step 'check policy': distinct policy failure" }
    ) {
        $suffix = @'
[pscustomobject]@{
    Status = 'fail'
    Steps = @(
        [pscustomobject]@{ Step = 'lint'; Status = 'fail'; Error = $null; Result = $lintResult }
        [pscustomobject]@{ Step = 'check policy'; Status = 'error'; Error = __ERROR__; Result = __RESULT__ }
    )
}
'@
        $body = $script:presentedLintBody + "`n" + $suffix.Replace('__ERROR__', $ErrorExpression).Replace('__RESULT__', $ResultExpression)
        $result = Invoke-AvmChildVerb -Mode File -Body $body

        $result.ExitCode | Should -Not -Be 0
        $annotations = @($result.Output -split "`n" | Where-Object { $_ -like '::error*' })
        $annotations.Count | Should -Be 2
        $annotations[0] | Should -BeExactly '::error file=examples/default/variables.tf,line=11,col=3::[terraform_unused_declarations] unused location'
        $annotations[1] | Should -BeExactly $Annotation
    }
}

Describe 'Invoke-Avm result rendering (F20/F21)' {
    It 'renders a successful result and its issues' {
        $body = @"
[pscustomobject]@{
    Status = 'pass'
    Issues = @([pscustomobject]@{
        Severity = 'warning'; File = 'variables.tf'; Line = 2; Column = 1
        Code = 'avm.warning'; Message = 'visible warning'
    })
}
"@
        $result = Invoke-AvmChildVerb -Mode File -Body $body
        $result.Output | Should -Match 'avm spec-verb: pass'
        $result.Output | Should -Match 'variables\.tf:2:1'
        $result.Output | Should -Match 'visible warning'
    }

    It 'renders chain step statuses, errors, and nested issues before throwing' {
        $body = @"
[pscustomobject]@{
    Status = 'error'
    Steps = @(
        [pscustomobject]@{ Step = 'format'; Status = 'pass'; Error = `$null; Result = `$null; DurationMs = 4 }
        [pscustomobject]@{
            Step = 'transform'; Status = 'error'; Error = 'mapotf failed'
            DurationMs = 9
            Result = [pscustomobject]@{
                Issues = @([pscustomobject]@{
                    Severity = 'error'; File = 'main.tf'; Line = 0; Column = 0
                    Code = ''; Message = 'nested detail'
                })
            }
        }
    )
}
"@
        $result = Invoke-AvmChildVerb -Mode File -Body $body
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match '\[pass\] format'
        $result.Output | Should -Match '\[error\] transform'
        $result.Output | Should -Match 'mapotf failed'
        $result.Output | Should -Match 'nested detail'
    }
}

Describe 'Invoke-Avm renders once per invocation (F25)' {
    It 'emits a single summary line and labels each item with its own identity' {
        $body = @"
@(
    [pscustomobject]@{ Name = 'terraform'; Status = 'installed' }
    [pscustomobject]@{ Name = 'tflint';    Status = 'installed' }
    [pscustomobject]@{ Name = 'conftest';  Status = 'not-installed' }
)
"@
        $result = Invoke-AvmChildVerb -Mode File -Body $body
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'avm spec-verb: 3 results'
        $result.Output | Should -Match '\[installed\] terraform'
        $result.Output | Should -Match '\[installed\] tflint'
        $result.Output | Should -Match '\[not-installed\] conftest'
        @($result.Output -split "`n" | Where-Object { $_ -match '^avm spec-verb' }).Count | Should -Be 1
    }

    It 'still renders a bare status line for a single result' {
        $result = Invoke-AvmChildVerb -Mode File -Body "[pscustomobject]@{ Status = 'pass' }"
        $result.Output | Should -Match 'avm spec-verb: pass'
        $result.Output | Should -Not -Match 'results'
    }
}

Describe 'Invoke-Avm result object suppression (F23)' {
    It 'does not dump the raw result object by default' {
        $body = "[pscustomobject]@{ Status = 'pass'; Marker = 'RAW-OBJECT-MARKER' }"
        $result = Invoke-AvmChildVerb -Mode File -Body $body -Invocation 'avm spec-verb'
        $result.Output | Should -Match 'avm spec-verb: pass'
        $result.Output | Should -Not -Match 'RAW-OBJECT-MARKER'
    }

    It 'returns the raw result object when --passthru is supplied' {
        $body = "[pscustomobject]@{ Status = 'pass'; Marker = 'RAW-OBJECT-MARKER' }"
        $result = Invoke-AvmChildVerb -Mode File -Body $body -Invocation 'avm spec-verb --passthru'
        $result.Output | Should -Match 'RAW-OBJECT-MARKER'
    }

    It 'streams objects that carry no Status property regardless of --passthru' {
        $body = "[pscustomobject]@{ Marker = 'READ-VERB-MARKER' }"
        $result = Invoke-AvmChildVerb -Mode File -Body $body -Invocation 'avm spec-verb'
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'READ-VERB-MARKER'
    }
}

Describe 'Invoke-Avm clean failure reporting (F24)' {
    It 'renders a one-line failure summary without a source-line stack trace' {
        $result = Invoke-AvmChildVerb -Mode File -Body "[pscustomobject]@{ Status = 'fail' }"
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match "reported Status 'fail'"
        $result.Output | Should -Not -Match 'Invoke-Avm\.ps1:\d+'
        $result.Output | Should -Not -Match '~~~~'
    }

    It 'keeps the non-zero process exit under pwsh -Command' {
        $result = Invoke-AvmChildVerb -Mode Command -Body "[pscustomobject]@{ Status = 'error' }"
        $result.ExitCode | Should -Not -Be 0
        # F47: the positive anchor is load-bearing. Without it the negative below
        # passes on an empty capture, so a tool that failed while printing nothing
        # would satisfy the only assertion guarding the failure summary.
        $result.Output | Should -Match "reported Status 'error'"
        $result.Output | Should -Not -Match 'Invoke-Avm\.ps1:\d+'
    }
}

Describe 'Invoke-Avm typed exception reporting (F24)' {
    It 'renders a typed AvmException as a one-line failure without a stack trace' {
        $body = "throw [AvmConfigurationException]::new('bad selector value')"
        $result = Invoke-AvmChildVerb -Mode File -Body $body
        $result.ExitCode | Should -Not -Be 0
        $result.Output   | Should -Match 'avm spec-verb failed: bad selector value'
        $result.Output   | Should -Not -Match '~~~~'
        $result.Output   | Should -Not -Match '\.ps1:\d+'
    }

    It 'preserves the typed exception for callers that catch it' {
        $result = Invoke-AvmChildVerb -Mode File -CaptureTypedError -Body "throw [AvmConfigurationException]::new('bad selector value')"
        $result.Output | Should -Match 'AvmConfigurationException'
    }
}
