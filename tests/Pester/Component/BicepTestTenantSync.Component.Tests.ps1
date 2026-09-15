BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:entryPath = Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'Invoke-BicepTestTenantSync.ps1'
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $script:sourceValues = [ordered]@{
        TEST_BAMI_TENANT_ID = '11111111-1111-4111-8111-111111111111'
        TEST_BAMI_CONTROLLER_CLIENT_ID = '22222222-2222-4222-8222-222222222222'
        TEST_BAMI_ADMIN_SUBSCRIPTION_ID = '33333333-3333-4333-8333-333333333333'
        TEST_BAMI_SUBSCRIPTION_IDS = ConvertTo-Json -InputObject @(
            1..28 | ForEach-Object {
                @{ name = "bami-sub-$_"; id = ('66666666-6666-4666-8666-{0:d12}' -f $_) }
            }
        ) -Depth 5 -Compress
        TEST_BAMI_MANAGEMENT_GROUP_ID = 'bami-test'
        TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME = 'rg-bami-test'
        TEST_BAMI_BICEP_CLIENT_ID = '44444444-4444-4444-8444-444444444444'
        TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID = '55555555-5555-4555-8555-555555555555'
    }
    $script:originalEnvironment = @{}
    foreach ($variableName in (@($script:sourceValues.Keys) + @('GH_TOKEN', 'AVM_OFFLINE'))) {
        $script:originalEnvironment[$variableName] = [System.Environment]::GetEnvironmentVariable($variableName)
    }

    function New-BicepEntryVariable {
        param([string] $Name, [string] $Value, [int] $Revision = 0)

        @{
            name = $Name
            value = $Value
            created_at = '2026-09-01T00:00:00Z'
            updated_at = [datetime]::new(2026, 9, 15, 0, 0, 0, [System.DateTimeKind]::Utc).AddSeconds($Revision).ToString('O')
        }
    }
}

Describe 'Bicep test tenant entry point with real configuration and mocked GitHub' -Tag Component {
    BeforeEach {
        foreach ($variableName in $script:sourceValues.Keys) {
            [System.Environment]::SetEnvironmentVariable($variableName, $script:sourceValues[$variableName])
        }
        $env:GH_TOKEN = 'fixture-installation-token'
        $env:AVM_OFFLINE = '0'
        $script:entryState = @{
            Variables = [ordered]@{
                ARM_TENANT_ID = New-BicepEntryVariable -Name 'ARM_TENANT_ID' -Value 'legacy-value'
                TEST_BAMI_CONTROLLER_CLIENT_ID = New-BicepEntryVariable -Name 'TEST_BAMI_CONTROLLER_CLIENT_ID' -Value 'existing-value-not-owned-by-this-sync'
            }
            WriteNames = [System.Collections.Generic.List[string]]::new()
            LostSelectorResponse = $false
            BlockedExecutable = Join-Path $TestDrive 'gh-must-never-start'
        }
        $entryState = $script:entryState
        $newVariable = ${function:New-BicepEntryVariable}
        Mock Import-Module {}
        Mock Get-Command ({ [pscustomobject]@{ Source = $entryState.BlockedExecutable } }.GetNewClosure()) -ParameterFilter {
            $Name -ceq 'gh' -and $CommandType -eq 'Application'
        }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith ({
            param($FilePath, $ArgumentList, $EnvVars)
            $FilePath | Should -BeExactly $entryState.BlockedExecutable
            $ArgumentList[0] | Should -BeExactly 'api'
            $ArgumentList[2] | Should -BeExactly 'github.com'
            $EnvVars.GH_TOKEN | Should -BeExactly 'fixture-installation-token'
            if ($ArgumentList[4] -ceq 'GET') {
                $ArgumentList[11] | Should -BeExactly 'repos/Azure/bicep-registry-modules/actions/variables?per_page=100&page=1'
                return [pscustomobject]@{
                    ExitCode = 0
                    StdOut = ConvertTo-Json -InputObject @{
                        total_count = $entryState.Variables.Count
                        variables = @($entryState.Variables.Values)
                    } -Depth 10 -Compress
                    StdErr = ''
                }
            }
            $ArgumentList[4] | Should -BeIn @('POST', 'PATCH')
            $ArgumentList[12] | Should -BeExactly '--raw-field'
            $ArgumentList[13] | Should -BeLike 'name=TEST_BAMI_*'
            $ArgumentList[14] | Should -BeExactly '--raw-field'
            $ArgumentList[15] | Should -BeLike 'value=*'
            $variableName = $ArgumentList[13].Substring(5)
            $variableName | Should -BeIn @(
                'TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_SUBSCRIPTION_IDS',
                'TEST_BAMI_MANAGEMENT_GROUP_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID', 'TEST_BAMI_MODULE_CONFIG'
            )
            $entryState.WriteNames.Add($variableName)
            $entryState.Variables[$variableName] = & $newVariable -Name $variableName `
                -Value $ArgumentList[15].Substring(6) -Revision $entryState.WriteNames.Count
            if ($entryState.LostSelectorResponse -and $variableName -ceq 'TEST_BAMI_MODULE_CONFIG') {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Response lost (HTTP 502)' }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }.GetNewClosure())
    }

    AfterEach {
        foreach ($variableName in $script:originalEnvironment.Keys) {
            [System.Environment]::SetEnvironmentVariable($variableName, $script:originalEnvironment[$variableName])
        }
    }

    It 'plans by default from any working directory without writing variables' {
        Push-Location $TestDrive
        try { $result = & $script:entryPath | ConvertFrom-Json -AsHashtable }
        finally { Pop-Location }
        $result.Status | Should -BeExactly 'Planned'
        $result.PlanOnly | Should -BeTrue
        $result.ChangedNames | Should -HaveCount 6
        $script:entryState.WriteNames | Should -HaveCount 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter { $ArgumentList[4] -ceq 'GET' }
    }

    It 'applies the real central canary selector last and leaves all unrelated variables untouched' {
        $result = & $script:entryPath -Apply | ConvertFrom-Json -AsHashtable
        $result.Status | Should -BeExactly 'Published'
        $script:entryState.WriteNames | Should -HaveCount 6
        $script:entryState.WriteNames[-1] | Should -BeExactly 'TEST_BAMI_MODULE_CONFIG'
        $script:entryState.Variables.TEST_BAMI_MODULE_CONFIG.value |
            Should -BeExactly '{"default":"legacy","modules":{"avm/res/network/front-door":"bami"}}'
        foreach ($variableName in @(
            'TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID',
            'TEST_BAMI_MANAGEMENT_GROUP_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID'
        )) {
            $script:entryState.Variables[$variableName].value | Should -BeExactly $script:sourceValues[$variableName]
        }
        $subscriptions = $script:entryState.Variables.TEST_BAMI_SUBSCRIPTION_IDS.value | ConvertFrom-Json -AsHashtable
        $subscriptions | Should -HaveCount 28
        @($subscriptions[0].Keys | Sort-Object) | Should -Be @('id', 'name')
        $script:entryState.Variables.ARM_TENANT_ID.value | Should -BeExactly 'legacy-value'
        $script:entryState.Variables.TEST_BAMI_CONTROLLER_CLIENT_ID.value | Should -BeExactly 'existing-value-not-owned-by-this-sync'
        $script:entryState.Variables.Contains('TEST_BAMI_ADMIN_SUBSCRIPTION_ID') | Should -BeFalse
        $script:entryState.Variables.Contains('TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME') | Should -BeFalse
        $result | ConvertTo-Json -Depth 5 | Should -Not -Match 'fixture-installation-token|11111111|22222222|33333333|rg-bami-test'
    }

    It 'propagates WhatIf as a write-free preview' {
        $result = & $script:entryPath -Apply -WhatIf | ConvertFrom-Json -AsHashtable
        $result.Status | Should -BeExactly 'Preview'
        $script:entryState.WriteNames | Should -HaveCount 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter { $ArgumentList[4] -ceq 'GET' }
    }

    It 'validates all source values before any mocked API call at the entry point' {
        $env:TEST_BAMI_CONTROLLER_CLIENT_ID = $env:TEST_BAMI_BICEP_CLIENT_ID
        { & $script:entryPath -Apply } | Should -Throw
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        $script:entryState.WriteNames | Should -HaveCount 0
    }

    It 'does not turn a lost selector response into a successful entry-point result' {
        $script:entryState.LostSelectorResponse = $true
        { & $script:entryPath -Apply } |
            Should -Throw '*Readback confirms the requested selector and unchanged execution values are present*'
        $script:entryState.WriteNames | Should -HaveCount 6
        $script:entryState.Variables.TEST_BAMI_MODULE_CONFIG.value |
            Should -BeExactly '{"default":"legacy","modules":{"avm/res/network/front-door":"bami"}}'
    }
}
