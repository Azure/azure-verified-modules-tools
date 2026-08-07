#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Set-StrictMode -Version 3.0

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    $script:manifestPath = Join-Path $script:moduleRoot 'Avm.Authoring.psd1'
    Import-Module $script:manifestPath -Force

    # Runs a fresh child pwsh that imports the module, replaces the verb registry
    # with a single fake verb whose cmdlet returns the supplied result object, then
    # invokes 'avm spec-verb'. Each child is isolated, so the observed process exit
    # mirrors how a `run:` step with `shell: pwsh` reacts in GitHub Actions.
    function script:Invoke-AvmChildVerb {
        param(
            [Parameter(Mandatory)][string] $Body,
            [ValidateSet('File', 'Command')][string] $Mode = 'File',
            [switch] $CaptureTypedError,
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

        $scriptText = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$manifest' -Force
`$module = Get-Module Avm.Authoring
& `$module {
    function script:Get-AvmVerbRegistry {
        [pscustomobject]@{ Path = [string[]]@('spec-verb'); Cmdlet = 'Invoke-AvmSpecVerb'; Summary = 'test verb' }
    }
    function script:Invoke-AvmSpecVerb { $Body }
}
$invoke
"@

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-f02-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Value $scriptText -Encoding utf8
        try {
            if ($Mode -eq 'File') {
                $out = & pwsh -NoProfile -File $tmp 2>&1
            } else {
                $out = & pwsh -NoProfile -Command ". '$tmp'" 2>&1
            }
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ((($out | ForEach-Object { [string]$_ }) -join "`n").Trim()) }
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
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

    It 'exits non-zero when the dispatcher rejects an outdated module' {
        $invocation = @'
$module = Get-Module Avm.Authoring
& $module {
    function script:Test-AvmModuleVersion {
        throw [AvmModuleVersionException]::new(
            [version]'0.2.3',
            [version]'0.3.0',
            'Avm.Authoring 0.2.3 is outdated.')
    }
}
avm spec-verb | Out-Null
'@
        $result = Invoke-AvmChildVerb -Mode File -Body "[pscustomobject]@{ Status = 'pass' }" -Invocation $invocation

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'avm spec-verb failed: Avm\.Authoring 0\.2\.3 is outdated'
        $result.Output | Should -Not -Match '~~~~'
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
