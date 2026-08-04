#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: avm command routes' -Tag 'Integration' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module $script:moduleManifest -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'finds the live PowerShell Gallery package as a module version' -Skip:(
        (Test-Path Env:\AVM_OFFLINE) -and $env:AVM_OFFLINE -eq '1') {
        $latestVersion = InModuleScope 'Avm.Authoring' {
            $script:AvmLatestModuleVersion = $null
            $script:AvmModuleVersionCheckCompleted = $false
            Get-AvmLatestModuleVersion
        }

        $latestVersion | Should -BeOfType [version]
        $latestVersion | Should -BeGreaterOrEqual (Get-Module Avm.Authoring).Version
    }

    It 'routes avm version and returns the loaded module version without warnings' {
        $records = @(avm version 3>&1)
        $warnings = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $result = @($records | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })

        $warnings.Count | Should -Be 0
        $result.Count | Should -Be 1
        $result[0].Module | Should -BeExactly 'Avm.Authoring'
        $result[0].Version | Should -Be (Get-Module Avm.Authoring).Version.ToString()
    }

    It 'routes avm doctor --json and returns valid diagnostics without warnings' {
        $records = @(avm doctor --json 3>&1)
        $warnings = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $result = @($records | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })

        $warnings.Count | Should -Be 0
        $result.Count | Should -Be 1
        $diagnostics = $result[0] | ConvertFrom-Json
        $diagnostics.Status | Should -Be 'OK'
        $diagnostics.Failed | Should -Be 0
    }

    It 'routes avm tool list with passthrough and returns every managed tool without warnings' {
        $records = @(avm tool list --passthru 3>&1 6>$null)
        $warnings = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $tools = @($records | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })

        $warnings.Count | Should -Be 0
        $tools.Count | Should -BeGreaterThan 0
        $tools.Name | Should -Contain 'terraform'
        @($tools | Where-Object { [string]::IsNullOrWhiteSpace($_.Version) }).Count | Should -Be 0
    }

    It 'routes every help form without warnings' -TestCases @(
        @{ HelpForm = 'bare' }
        @{ HelpForm = 'help' }
        @{ HelpForm = '--help' }
        @{ HelpForm = '-h' }
    ) {
        $records = @(
            switch ($HelpForm) {
                'bare' { avm 3>&1 6>&1 }
                'help' { avm help 3>&1 6>&1 }
                '--help' { avm --help 3>&1 6>&1 }
                '-h' { avm -h 3>&1 6>&1 }
            }
        )
        $warnings = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $helpText = $records | Where-Object {
            $_ -isnot [System.Management.Automation.WarningRecord]
        } | Out-String

        $warnings.Count | Should -Be 0
        $helpText | Should -Match 'Usage: avm <verb>'
        $helpText | Should -Match 'version'
        $helpText | Should -Match 'update'
    }
}
