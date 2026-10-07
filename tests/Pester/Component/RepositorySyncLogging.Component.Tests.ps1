BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $lib = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib'
    . (Join-Path $lib 'Logging.ps1')
    . (Join-Path $lib 'RetryHelpers.ps1')
    . (Join-Path $lib 'TerraformOperations.ps1')
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
    }

    It 'does not emit GitHub group commands outside Actions' {
        [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', [NullString]::Value, 'Process')
        $records = @()
        $null = Invoke-RepositorySyncLogGroup -Name 'Local details' -Action { 'data' } -InformationVariable records
        ($records | Out-String) | Should -Not -Match '::group::|::endgroup::'
    }
}
