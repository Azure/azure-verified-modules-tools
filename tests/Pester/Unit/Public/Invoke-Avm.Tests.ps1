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
            [switch] $CaptureTypedError
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
                $out = & pwsh -NoProfile -File $tmp
            } else {
                $out = & pwsh -NoProfile -Command ". '$tmp'"
            }
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($out -join "`n").Trim()) }
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
        $result.Output | Should -Be 'AvmCommandException|spec-verb|fail'
    }
}
