BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $lib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    . (Join-Path $lib 'RetryHelpers.ps1')
    . (Join-Path $lib 'Logging.ps1')
    . (Join-Path $lib 'UnmanagedRulesets.ps1')
}

Describe 'Unmanaged ruleset cleanup' {
    BeforeEach {
        Mock Invoke-GitHubCliWithRetry {
            @{
                success = $true
                output = @(
                    @{ id = 1; name = 'Azure Verified Modules'; source_type = 'Repository'; target = 'branch' }
                    @{ id = 2; name = 'Only allow v tags'; source_type = 'Repository'; target = 'tag' }
                    @{ id = 3; name = 'Must not delete/update version tags'; source_type = 'Repository'; target = 'tag' }
                    @{ id = 4; name = 'Restrict v1+ release tags'; source_type = 'Repository'; target = 'tag' }
                    @{ id = 5; name = 'Unmanaged rule'; source_type = 'Repository'; target = 'tag' }
                ) | ConvertTo-Json -Compress
            }
        } -ParameterFilter { $commands[0].Arguments -notcontains 'DELETE' }

        Mock Invoke-GitHubCliWithRetry { @{ success = $true } } `
            -ParameterFilter { $commands[0].Arguments -contains 'DELETE' }
        Mock Add-IssueToLog { throw 'Unexpected ruleset cleanup error.' }
    }

    It 'preserves all managed rulesets and removes only unmanaged rules in apply mode' {
        $result = Remove-UnmanagedRulesets -orgAndRepoName 'Azure/example' -planOnly $false -issueLog @()

        $result.RemovedCount | Should -Be 1
        $result.DetectedNames | Should -Be @('Unmanaged rule')
        Should -Invoke Invoke-GitHubCliWithRetry -Times 1 -Exactly -ParameterFilter {
            $commands[0].Arguments -contains 'DELETE' -and
            $commands[0].Arguments -contains 'repos/Azure/example/rulesets/5'
        }
        Should -Invoke Invoke-GitHubCliWithRetry -Times 2 -Exactly
        Should -Invoke Add-IssueToLog -Times 0
    }

    It 'keeps plan mode non-writing while recognizing the v1+ restriction' {
        $result = Remove-UnmanagedRulesets -orgAndRepoName 'Azure/example' -planOnly $true -issueLog @()

        $result.RemovedCount | Should -Be 0
        $result.DetectedNames | Should -Be @('Unmanaged rule')
        Should -Invoke Invoke-GitHubCliWithRetry -Times 0 -Exactly -ParameterFilter {
            $commands[0].Arguments -contains 'DELETE'
        }
        Should -Invoke Add-IssueToLog -Times 0
    }
}
