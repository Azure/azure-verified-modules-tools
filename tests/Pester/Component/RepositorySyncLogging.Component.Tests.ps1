BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $lib = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib'
    . (Join-Path $lib 'Logging.ps1')
    . (Join-Path $lib 'RetryHelpers.ps1')
    . (Join-Path $lib 'TerraformOperations.ps1')
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $script:pwshPath = (Get-Process -Id $PID).Path
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Repository sync folded native logs' -Tag Component {
    BeforeEach {
        $script:previous = @{}
        foreach ($name in @('GITHUB_ACTIONS', 'GH_TOKEN')) {
            $script:previous[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:GITHUB_ACTIONS = 'true'
        $env:GH_TOKEN = 'synthetic-token-do-not-print'
        Mock Invoke-RepositorySyncProcess {
            @{ ExitCode = 0; StdOut = 'native resource diff and Plan: 1 to add'; StdErr = 'native provider warning' }
        }
    }

    AfterEach {
        foreach ($name in $script:previous.Keys) {
            $value = $script:previous[$name]
            [Environment]::SetEnvironmentVariable($name, ($null -eq $value ? [NullString]::Value : $value), 'Process')
        }
    }

    It 'folds full successful output without adding log commands to returned data' {
        $records = [System.Collections.Generic.List[object]]::new()
        $result = Invoke-RepositorySyncLogGroup -Name 'Terraform details' -Action {
            Invoke-RepositorySyncTerraform -Root $TestDrive -Arguments @('plan')
            @{ result = 'unchanged-data' }
        } -InformationVariable records
        $result.result | Should -Be 'unchanged-data'
        @($result).Count | Should -Be 1
        $text = @($records | ForEach-Object { [string]$_.MessageData })
        $text[0] | Should -Be '::group::Terraform details'
        $text[-1] | Should -Be '::endgroup::'
        $text -join "`n" | Should -Match 'native resource diff'
        $text -join "`n" | Should -Match 'native provider warning'
    }

    It 'closes failed groups before exposing redacted native failure details' {
        Mock Invoke-RepositorySyncProcess {
            @{ ExitCode = 9; StdOut = "native stdout $env:GH_TOKEN"; StdErr = 'actionable native stderr' }
        }
        $records = @()
        $caught = $null
        try {
            Invoke-RepositorySyncLogGroup -Name 'Terraform details' -Action {
                Invoke-RepositorySyncTerraform -Root $TestDrive -Arguments @('apply')
            } -InformationVariable records
        }
        catch { $caught = $_.Exception }
        @($records)[-1].MessageData | Should -Be '::endgroup::'
        $caught.Data['ExitCode'] | Should -Be 9
        $caught.Message | Should -Match 'native stdout \*\*\*'
        $caught.Message | Should -Match 'actionable native stderr'
        $caught.Message | Should -Not -Match 'synthetic-token-do-not-print'
    }

    It 'retains timeout diagnostics but closes the group and redacts credentials' {
        Mock Invoke-RepositorySyncProcess {
            $timeout = [System.TimeoutException]::new('synthetic timeout')
            $timeout.Data['StdOut'] = "partial stdout $env:GH_TOKEN"
            $timeout.Data['StdErr'] = 'partial stderr'
            throw $timeout
        }
        $records = @()
        $caught = $null
        try {
            Invoke-RepositorySyncLogGroup -Name 'Terraform details' -Action {
                Invoke-RepositorySyncTerraform -Root $TestDrive -Arguments @('apply')
            } -InformationVariable records
        }
        catch { $caught = $_.Exception }
        @($records)[-1].MessageData | Should -Be '::endgroup::'
        $caught | Should -BeOfType ([System.TimeoutException])
        $caught.Message | Should -Match 'partial stdout \*\*\*'
        $caught.Message | Should -Match 'partial stderr'
        $caught.Message | Should -Not -Match 'synthetic-token-do-not-print'
    }

    It 'never logs machine JSON, including error and timeout paths: <Mode>' -ForEach @(
        @{ Mode = 'success' }
        @{ Mode = 'failure' }
        @{ Mode = 'timeout' }
    ) {
        $modeValue = $Mode
        Mock Invoke-RepositorySyncProcess ({
            if ($modeValue -ceq 'timeout') {
                $timeout = [System.TimeoutException]::new('synthetic timeout')
                $timeout.Data['StdOut'] = '{"private":"must-stay-private"}'
                $timeout.Data['StdErr'] = 'must-stay-private'
                throw $timeout
            }
            @{ ExitCode = ($modeValue -ceq 'failure' ? 1 : 0); StdOut = '{"private":"must-stay-private"}'; StdErr = 'must-stay-private' }
        }.GetNewClosure())
        $records = @()
        $caught = $null
        $result = $null
        try {
            $result = Invoke-RepositorySyncTerraform -Root $TestDrive -Arguments @('show', '-json', 'synthetic.tfplan') -Json -InformationVariable records
        }
        catch { $caught = $_.Exception }
        ($records | Out-String) | Should -Not -Match 'must-stay-private'
        if ($Mode -ceq 'success') {
            $result.private | Should -Be 'must-stay-private'
        } else {
            $caught | Should -Not -BeNullOrEmpty
            $caught.Message | Should -Not -Match 'must-stay-private'
            $caught.Data.Contains('StdOut') | Should -BeFalse
        }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter { $null -eq $OnOutputLine }
    }

    It 'retains quiet successful output without installing streaming callbacks' {
        $records = @()
        $result = Invoke-RepositorySyncTerraform -Root $TestDrive -Arguments @('plan') -Quiet -InformationVariable records
        $result | Should -BeNullOrEmpty
        $records | Should -BeNullOrEmpty
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter { $null -eq $OnOutputLine }
    }

    It 'rejects streaming private output before invoking a process: <Mode>' -ForEach @(
        @{ Mode = 'Json'; Options = @{ Json = $true }; Arguments = @('show', 'saved.tfplan') }
        @{ Mode = 'Quiet'; Options = @{ Quiet = $true }; Arguments = @('plan') }
        @{ Mode = 'native JSON'; Options = @{}; Arguments = @('show', '-json', 'saved.tfplan') }
        @{ Mode = 'native JSON assignment'; Options = @{}; Arguments = @('show', '-json=true', 'saved.tfplan') }
        @{ Mode = 'native double-hyphen JSON'; Options = @{}; Arguments = @('show', '--json', 'saved.tfplan') }
        @{ Mode = 'native double-hyphen JSON assignment'; Options = @{}; Arguments = @('show', '--json=true', 'saved.tfplan') }
    ) {
        { Invoke-RepositorySyncTerraform -Root $TestDrive -Arguments $Arguments -StreamOutput @Options } |
            Should -Throw '*human-readable Terraform output*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'redacts partial streamed diagnostics on timeout without exposing captured data' {
        Mock Invoke-RepositorySyncProcess {
            param($OnOutputLine)
            & $OnOutputLine 'resource.example: Still creating... child-only-secret'
            $timeout = [System.TimeoutException]::new('synthetic timeout')
            $timeout.Data['StdOut'] = 'resource.example: Still creating... child-only-secret'
            $timeout.Data['StdErr'] = "provider error $env:GH_TOKEN"
            throw $timeout
        }
        $records = @()
        $caught = $null
        try {
            Invoke-RepositorySyncTerraform -Root $TestDrive -Arguments @('apply', 'saved.tfplan') -StreamOutput `
                -Environment @{ ARM_CLIENT_SECRET = 'child-only-secret' } -InformationVariable records
        }
        catch { $caught = $_.Exception }
        $caught | Should -BeOfType ([System.TimeoutException])
        $caught.Data.Contains('StdOut') | Should -BeFalse
        $caught.Message | Should -Match 'Still creating\.\.\. \*\*\*'
        $caught.Message | Should -Match 'provider error \*\*\*'
        ($records | Out-String) | Should -Match 'Still creating\.\.\. \*\*\*'
        @($caught.Message, ($records | Out-String)) -join "`n" |
            Should -Not -Match 'child-only-secret|synthetic-token-do-not-print'
    }

    It 'does not emit GitHub group commands outside Actions' {
        [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', [NullString]::Value, 'Process')
        $records = @()
        $null = Invoke-RepositorySyncLogGroup -Name 'Local details' -Action { 'data' } -InformationVariable records
        ($records | Out-String) | Should -Not -Match '::group::|::endgroup::'
    }
}

Describe 'Repository Terraform incremental output' -Tag Component {
    BeforeEach {
        $script:previousActions = $env:GITHUB_ACTIONS
        $env:GITHUB_ACTIONS = 'true'
        $script:childPath = Join-Path $TestDrive 'streaming.ps1'
        $script:ackOut = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.stdout')
        $script:ackErr = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.stderr')
        @'
param([string] $AckOut, [string] $AckErr, [int] $ExitCode)
[Console]::Out.WriteLine('azapi_resource.identity: Creating id-test-bicep-avm-res-storage-storage-account...')
[Console]::Out.WriteLine('client_id = 10000000-0000-4000-8000-000000000006')
[Console]::Out.WriteLine('sensitive_attribute = (sensitive value)')
[Console]::Error.WriteLine("provider warning $env:ARM_CLIENT_SECRET")
[Console]::Out.Flush()
[Console]::Error.Flush()
$deadline = [datetime]::UtcNow.AddSeconds(10)
while ((-not [IO.File]::Exists($AckOut) -or -not [IO.File]::Exists($AckErr)) -and [datetime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 20
}
if (-not [IO.File]::Exists($AckOut) -or -not [IO.File]::Exists($AckErr)) { exit 19 }
[Console]::Out.WriteLine('azapi_resource.identity: Creation complete after 1s')
exit $ExitCode
'@ | Set-Content -LiteralPath $script:childPath -Encoding utf8NoBOM
        Mock Get-Command {
            [pscustomobject]@{ Source = $script:pwshPath }
        } -ParameterFilter { $Name -eq 'terraform' -and $CommandType -eq 'Application' }
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $script:previousActions)
    }

    It 'publishes redacted resource progress before the child can exit with <ExitCode>' -ForEach @(
        @{ ExitCode = 0 }
        @{ ExitCode = 7 }
    ) {
        $messages = [System.Collections.Generic.List[string]]::new()
        $caught = $null
        try {
            Invoke-RepositorySyncTerraform -Root $TestDrive -StreamOutput -Arguments @(
                '-NoProfile', '-NonInteractive', '-File', $script:childPath, $script:ackOut, $script:ackErr, [string]$ExitCode
            ) -Environment @{ ARM_CLIENT_SECRET = "private-first-line`nprivate-second-line" } 6>&1 |
                ForEach-Object {
                    $text = [string]$_.MessageData
                    $messages.Add($text)
                    if ($text -cmatch 'Creating id-test-bicep-avm-res-storage-storage-account') {
                        [IO.File]::WriteAllText($script:ackOut, 'observed live stdout')
                    }
                    if ($text -ceq 'provider warning ***') {
                        [IO.File]::WriteAllText($script:ackErr, 'observed live redacted stderr')
                    }
                }
        }
        catch { $caught = $_.Exception }
        Test-Path -LiteralPath $script:ackOut | Should -BeTrue
        Test-Path -LiteralPath $script:ackErr | Should -BeTrue
        $messages | Should -Contain 'azapi_resource.identity: Creation complete after 1s'
        $messages | Should -Contain 'client_id = 10000000-0000-4000-8000-000000000006'
        $messages | Should -Contain 'sensitive_attribute = (sensitive value)'
        $messages | Should -Contain '***'
        ($messages -join "`n") | Should -Not -Match 'private-first-line|private-second-line'
        if ($ExitCode -eq 0) {
            $caught | Should -BeNullOrEmpty
            @($messages | Where-Object { $_ -cmatch 'Creation complete after 1s' }).Count | Should -Be 1
        }
        else {
            $caught | Should -BeOfType ([System.InvalidOperationException])
            $caught.Data['ExitCode'] | Should -Be 7
            $caught.Message | Should -Match 'no automatic apply retry or state repair'
            $caught.Message | Should -Not -Match 'private-first-line|private-second-line'
        }
    }
}
