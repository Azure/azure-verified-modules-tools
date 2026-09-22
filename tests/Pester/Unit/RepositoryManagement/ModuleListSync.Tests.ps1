BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $sharedLib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    $reviewerRoutingLib = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'lib'
    $lib = Join-Path $root 'repository-management' 'module-list-sync' 'scripts' 'lib'
    . (Join-Path $sharedLib 'RetryHelpers.ps1')
    . (Join-Path $sharedLib 'RepoTree.ps1')
    . (Join-Path $sharedLib 'RepositoryFileSync.ps1')
    . (Join-Path $reviewerRoutingLib 'RepositoryFileAccess.ps1')
    . (Join-Path $reviewerRoutingLib 'ModuleOwners.ps1')
    . (Join-Path $lib 'ModuleListSync.ps1')

    function New-ModuleDropdownFixtureContent {
        @'
name: AVM - Module Issue
body:
  - type: dropdown
    id: module-name-dropdown
    attributes:
      label: Module Name
      options:
        - ""
        - "avm/ptn/foo/bar"
        - "avm/ptn/foo/baz"
        # - "avm/ptn/hidden/one"
        - "avm/res/aaa/bbb"
        - "avm/res/ccc/ddd"
        - "avm/utl/types/avm-common-types"
    validations:
      required: true
'@
    }
}

Describe 'Get-AvmModuleListSyncCatalogModulePaths' {
    It 'groups Available modules by category and drops other repositories/statuses' {
        Mock Get-AvmReviewerRoutingCatalogIndex {
            @{
                'avm/res/aaa/bbb' = @{ modulePath = 'avm/res/aaa/bbb'; moduleStatus = 'Available'; parentModule = $null }
                'avm/ptn/foo/bar' = @{ modulePath = 'avm/ptn/foo/bar'; moduleStatus = 'Available'; parentModule = $null }
                'avm/res/zzz/yyy' = @{ modulePath = 'avm/res/zzz/yyy'; moduleStatus = 'Deprecated'; parentModule = $null }
            }
        }
        $result = Get-AvmModuleListSyncCatalogModulePaths -Repository 'Azure/bicep-registry-modules'
        $result.res | Should -Be @('avm/res/aaa/bbb')
        $result.ptn | Should -Be @('avm/ptn/foo/bar')
        $result.utl | Should -HaveCount 0
    }

    It 'includes Orphaned modules alongside Available and drops Proposed/Deprecated' {
        Mock Get-AvmReviewerRoutingCatalogIndex {
            @{
                'avm/res/aaa/bbb' = @{ modulePath = 'avm/res/aaa/bbb'; moduleStatus = 'Available'; parentModule = $null }
                'avm/res/ccc/ddd' = @{ modulePath = 'avm/res/ccc/ddd'; moduleStatus = 'Orphaned'; parentModule = $null }
                'avm/res/eee/fff' = @{ modulePath = 'avm/res/eee/fff'; moduleStatus = 'Proposed'; parentModule = $null }
                'avm/res/ggg/hhh' = @{ modulePath = 'avm/res/ggg/hhh'; moduleStatus = 'Deprecated'; parentModule = $null }
            }
        }
        $result = Get-AvmModuleListSyncCatalogModulePaths -Repository 'Azure/bicep-registry-modules'
        $result.res | Should -Be @('avm/res/aaa/bbb', 'avm/res/ccc/ddd')
    }

    It 'includes only top-level Available/Orphaned modules and drops top-level Proposed/Deprecated and all child modules' {
        Mock Get-AvmReviewerRoutingCatalogIndex {
            @{
                'avm/res/top-available' = @{ modulePath = 'avm/res/top-available'; moduleStatus = 'Available'; parentModule = $null }
                'avm/res/top-orphaned' = @{ modulePath = 'avm/res/top-orphaned'; moduleStatus = 'Orphaned'; parentModule = $null }
                'avm/res/top-proposed' = @{ modulePath = 'avm/res/top-proposed'; moduleStatus = 'Proposed'; parentModule = $null }
                'avm/res/top-deprecated' = @{ modulePath = 'avm/res/top-deprecated'; moduleStatus = 'Deprecated'; parentModule = $null }
                'avm/res/child-available' = @{ modulePath = 'avm/res/child-available'; moduleStatus = 'Available'; parentModule = 'avm/res/top-available' }
                'avm/res/child-orphaned' = @{ modulePath = 'avm/res/child-orphaned'; moduleStatus = 'Orphaned'; parentModule = 'avm/res/top-orphaned' }
            }
        }
        $result = Get-AvmModuleListSyncCatalogModulePaths -Repository 'Azure/bicep-registry-modules'
        $result.res | Should -Be @('avm/res/top-available', 'avm/res/top-orphaned')
    }
}

Describe 'Resolve-AvmModuleDropdownSync' {
    BeforeEach {
        $script:content = New-ModuleDropdownFixtureContent
        $script:desired = @{
            ptn = @('avm/ptn/foo/bar', 'avm/ptn/foo/baz')
            res = @('avm/res/aaa/bbb', 'avm/res/ccc/ddd')
            utl = @('avm/utl/types/avm-common-types')
        }
    }

    It 'reports no change when the dropdown already matches the catalog' {
        $result = Resolve-AvmModuleDropdownSync -Content $script:content -DesiredModulePaths $script:desired
        $result.Changed | Should -BeFalse
        $result.Added | Should -HaveCount 0
        $result.Removed | Should -HaveCount 0
    }

    It 'preserves commented-out lines untouched' {
        $result = Resolve-AvmModuleDropdownSync -Content $script:content -DesiredModulePaths $script:desired
        $result.Content | Should -Match '# - "avm/ptn/hidden/one"'
    }

    It 'detects a module missing from the dropdown' {
        $script:desired.res += 'avm/res/new/module'
        $result = Resolve-AvmModuleDropdownSync -Content $script:content -DesiredModulePaths $script:desired
        $result.Changed | Should -BeTrue
        $result.Added | Should -Contain 'avm/res/new/module'
        $result.Content | Should -Match '"avm/res/new/module"'
    }

    It 'detects a module no longer in the catalog and drops it' {
        $script:desired.res = @('avm/res/aaa/bbb')
        $result = Resolve-AvmModuleDropdownSync -Content $script:content -DesiredModulePaths $script:desired
        $result.Changed | Should -BeTrue
        $result.Removed | Should -Contain 'avm/res/ccc/ddd'
        $result.Content | Should -Not -Match '"avm/res/ccc/ddd"'
    }

    It 'corrects an out-of-order active entry' {
        $search = "        - `"avm/res/aaa/bbb`"`n        - `"avm/res/ccc/ddd`""
        $unsorted = $script:content.Replace(
            $search,
            "        - `"avm/res/ccc/ddd`"`n        - `"avm/res/aaa/bbb`"")
        $unsorted | Should -Not -Be $script:content
        $result = Resolve-AvmModuleDropdownSync -Content $unsorted -DesiredModulePaths $script:desired
        $result.Changed | Should -BeTrue
        ($result.Content -split "`n" | Where-Object { $_ -match '"avm/res/' }) | Should -Be @('        - "avm/res/aaa/bbb"', '        - "avm/res/ccc/ddd"')
    }

    It 'throws when the dropdown block cannot be found' {
        { Resolve-AvmModuleDropdownSync -Content "no dropdown here`n" -DesiredModulePaths $script:desired } | Should -Throw
    }
}

Describe 'New-AvmModuleListSyncPullRequestBody' {
    It 'lists added and removed module paths' {
        $body = New-AvmModuleListSyncPullRequestBody -Added @('avm/res/new/module') -Removed @('avm/res/old/module')
        $body | Should -Match 'avm/res/new/module'
        $body | Should -Match 'avm/res/old/module'
    }

    It 'omits empty added/removed sections' {
        $body = New-AvmModuleListSyncPullRequestBody -Added @() -Removed @()
        $body | Should -Not -Match '\*\*Added:\*\*'
        $body | Should -Not -Match '\*\*Removed:\*\*'
    }
}

Describe 'Invoke-AvmModuleListSync' {
    BeforeEach {
        Mock Get-AvmModuleListSyncCatalogModulePaths {
            @{
                ptn = @('avm/ptn/foo/bar', 'avm/ptn/foo/baz')
                res = @('avm/res/aaa/bbb', 'avm/res/ccc/ddd')
                utl = @('avm/utl/types/avm-common-types')
            }
        }
        Mock Get-AvmRepositoryFileAtRef { [pscustomobject]@{ Content = (New-ModuleDropdownFixtureContent); Sha = 'deadbeef' } }
        Mock Invoke-RepositoryFileSync { @{ HasChanges = $true; Status = 'ReviewRequired'; PullRequestUrl = 'https://github.com/Azure/bicep-registry-modules/pull/1' } }
    }

    It 'does not open a pull request when the dropdown already matches the catalog' {
        $result = Invoke-AvmModuleListSync -Repository 'Azure/bicep-registry-modules'
        $result.HasChanges | Should -BeFalse
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }

    It 'opens a review-required pull request through the shared sync engine when drift is found' {
        Mock Get-AvmModuleListSyncCatalogModulePaths {
            @{
                ptn = @('avm/ptn/foo/bar', 'avm/ptn/foo/baz')
                res = @('avm/res/aaa/bbb', 'avm/res/ccc/ddd', 'avm/res/new/module')
                utl = @('avm/utl/types/avm-common-types')
            }
        }
        $result = Invoke-AvmModuleListSync -Repository 'Azure/bicep-registry-modules'
        $result.PullRequestUrl | Should -Be 'https://github.com/Azure/bicep-registry-modules/pull/1'
        Should -Invoke Invoke-RepositoryFileSync -Times 1 -ParameterFilter {
            $ReviewOnly -and $VerifyCandidate -and $StableBranch -eq 'avm-bot/sync-module-dropdown' -and
            $ExpectedActor.login -eq 'azure-verified-modules[bot]' -and
            $GeneratedFiles.ContainsKey('.github/ISSUE_TEMPLATE/avm_module_issue.yml')
        }
    }
}

Describe 'Invoke-AvmModuleListSync diagnostics' {
    BeforeEach {
        Mock Get-AvmModuleListSyncCatalogModulePaths {
            @{
                ptn = @('avm/ptn/foo/bar', 'avm/ptn/foo/baz')
                res = @('avm/res/aaa/bbb', 'avm/res/ccc/ddd')
                utl = @('avm/utl/types/avm-common-types')
            }
        }
        Mock Get-AvmRepositoryFileAtRef { [pscustomobject]@{ Content = (New-ModuleDropdownFixtureContent); Sha = 'deadbeef' } }
    }

    It 'emits a progress marker before fetching or comparing anything' {
        $verboseOutput = Invoke-AvmModuleListSync -Repository 'Azure/bicep-registry-modules' -Verbose 4>&1 | Out-String
        $verboseOutput | Should -Match ([regex]::Escape('[1/1] Syncing module dropdown for [Azure/bicep-registry-modules]'))
    }

    It 'writes full exception detail and rethrows when pre-sync setup fails' {
        Mock Get-AvmModuleListSyncCatalogModulePaths { throw [System.InvalidOperationException]::new('catalog fetch boom') }
        $hostOutput = & {
            try { Invoke-AvmModuleListSync -Repository 'Azure/bicep-registry-modules' *>&1 }
            catch { "THREW: $($_.Exception.Message)" }
        } | Out-String
        $hostOutput | Should -Match 'catalog fetch boom'
        $hostOutput | Should -Match 'InvalidOperationException'
        $hostOutput | Should -Match 'THREW: catalog fetch boom'
    }
}

Describe 'Invoke-AvmModuleListSync entry point diagnostics' {
    BeforeAll {
        $script:entryPointPath = Join-Path $root 'repository-management' 'module-list-sync' 'scripts' 'Invoke-AvmModuleListSync.ps1'
        $script:entryPointText = Get-Content -Raw -Path $script:entryPointPath
    }

    It 'exists' {
        Test-Path $script:entryPointPath | Should -BeTrue
    }

    It 'wraps the sync invocation in a try/catch that prints a FATAL banner and rethrows' {
        $script:entryPointText | Should -Match '(?ms)try\s*\{\s*Invoke-AvmModuleListSync\b.*?\}\s*catch\s*\{.*?Write-Host\s+"FATAL:.*?Write-Host\s+\$_\.ScriptStackTrace.*?throw\s*\r?\n\}'
    }
}

Describe 'Module dropdown sync workflow safety' {
    BeforeAll {
        $script:workflowPath = Join-Path $root '.github' 'workflows' 'repository-management-module-list-sync.yml'
        $script:workflowText = Get-Content -Raw -Path $script:workflowPath
        $script:triggerBlock = [System.Text.RegularExpressions.Regex]::Match(
            $script:workflowText, '(?ms)^on:\r?\n(.*?)(?=^\S)').Groups[1].Value
        $script:runBlocks = [System.Text.RegularExpressions.Regex]::Matches(
            $script:workflowText, '(?ms)^        run:\s*\|\r?\n(?<body>.*?)(?=^      - |\z)')
    }

    It 'exists' {
        Test-Path $script:workflowPath | Should -BeTrue
    }

    It 'is triggered only by workflow_dispatch while live validation is pending' {
        $triggerNames = @([System.Text.RegularExpressions.Regex]::Matches(
                $script:triggerBlock, '(?m)^  ([A-Za-z_]+):') |
            ForEach-Object { $_.Groups[1].Value })
        $triggerNames.Count | Should -Be 1
        $triggerNames[0] | Should -Be 'workflow_dispatch'
        $script:triggerBlock | Should -Match '(?m)^\s{2}workflow_dispatch:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}schedule:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}issues:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request_target:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}workflow_run:'
    }

    It 'preserves the disabled schedule without schedule-dependent expressions' {
        $script:workflowText | Should -Match "'13 6 \* \* \*'"
        $script:workflowText | Should -Not -Match 'github\.event\.schedule'
    }

    It 'maps the what-if input directly' {
        $script:triggerBlock | Should -Match '(?ms)^      what_if:\r?\n.*?^        default:\s*true\s*$'
        $script:workflowText | Should -Match '(?m)^\s{10}WHAT_IF:\s*\$\{\{\s*inputs\.what_if\s*\}\}\s*$'
        $script:workflowText | Should -Match "\`$whatIf\s*=\s*\`$env:WHAT_IF\s*-eq\s*'true'"
    }

    It 'never interpolates ${{ }} expressions directly into a run: body' {
        $script:runBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $script:runBlocks) {
            $match.Groups['body'].Value | Should -Not -Match '\$\{\{'
        }
    }

    It 'imports Avm.Authoring in the work run block before invoking the repository-management script' {
        $workRunBlocks = @($script:runBlocks | Where-Object {
                $_.Groups['body'].Value -match '(?m)^\s*\./repository-management/.+\.ps1\b'
            })
        $workRunBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $workRunBlocks) {
            $runBody = $match.Groups['body'].Value
            $importIndex = $runBody.IndexOf('Import-Module Avm.Authoring -Force -ErrorAction Stop')
            $scriptIndex = [System.Text.RegularExpressions.Regex]::Match(
                $runBody, '(?m)^\s*\./repository-management/.+\.ps1\b').Index
            $importIndex | Should -BeGreaterThan -1
            $importIndex | Should -BeLessThan $scriptIndex
        }
    }

    It 'uses GH_TOKEN directly and clears native exit status after the work script' {
        $workRunBlocks = @($script:runBlocks | Where-Object {
                $_.Groups['body'].Value -match '(?m)^\s*\./repository-management/.+\.ps1\b'
            })
        $workRunBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $workRunBlocks) {
            $runBody = $match.Groups['body'].Value
            $runBody | Should -Not -Match '(?m)^\s*gh auth login\b'
            $scriptIndex = [System.Text.RegularExpressions.Regex]::Match(
                $runBody, '(?m)^\s*\./repository-management/.+\.ps1\b').Index
            $resetIndex = $runBody.LastIndexOf('$global:LASTEXITCODE = 0')
            $resetIndex | Should -BeGreaterThan $scriptIndex
            $runBody | Should -Match '(?s)\$global:LASTEXITCODE\s*=\s*0\s*\z'
        }
    }
}
