BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $workflowPath = Join-Path $root '.github' 'workflows' 'repository-management-regions-data-sync.yml'
    $workflowText = Get-Content -Raw -Path $workflowPath
    $triggerBlock = [System.Text.RegularExpressions.Regex]::Match(
        $workflowText, '(?ms)^on:\r?\n(.*?)(?=^\S)').Groups[1].Value
    $runBlocks = [System.Text.RegularExpressions.Regex]::Matches(
        $workflowText, '(?ms)^        run:\s*\|\r?\n(?<body>.*?)(?=^      - |\z)')
    $module = Import-Module (Join-Path $root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru
    $null = & $module { Import-AvmPowerShellModule -Name powershell-yaml -Global }
    $definition = ConvertFrom-Yaml -Yaml $workflowText
    $collectionStep = $definition.jobs.collect.steps | Where-Object name -EQ 'Regenerate locations data'
    $compareStep = $definition.jobs.collect.steps | Where-Object name -EQ 'Compare regions data'
    $publishStep = $definition.jobs.publish.steps | Where-Object name -EQ 'Validate and publish regions data'
}

Describe 'Regions data sync workflow safety' {
    It 'exists' {
        Test-Path $workflowPath | Should -BeTrue
    }

    It 'is triggered only by its weekly schedule and manual dispatch' {
        $triggerNames = @([System.Text.RegularExpressions.Regex]::Matches(
                $triggerBlock, '(?m)^  ([A-Za-z_]+):') |
            ForEach-Object { $_.Groups[1].Value })
        $triggerNames | Should -HaveCount 2
        $triggerNames | Should -Contain 'schedule'
        $triggerNames | Should -Contain 'workflow_dispatch'
        $triggerBlock | Should -Match "(?m)^    - cron: '15 4 \* \* 0'$"
        $triggerBlock | Should -Not -Match '(?m)^\s{2}issues:'
        $triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request:'
        $triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request_target:'
        $triggerBlock | Should -Not -Match '(?m)^\s{2}workflow_run:'
    }

    It 'is disabled until the trusted tools main workflow is explicitly enabled' {
        $guard = [regex]::Match($workflowText,
            '(?ms)^  collect:\r?\n    name: [^\r\n]+\r?\n    if: >-\r?\n(?<body>.*?)(?=^    runs-on:)')
        $guard.Success | Should -BeTrue
        ($guard.Groups['body'].Value.Trim() -replace '\s+', ' ') | Should -BeExactly (
            "github.repository == 'Azure/azure-verified-modules-tools' && " +
            '!github.event.repository.fork && ' +
            "github.ref == 'refs/heads/main' && " +
            "github.workflow_ref == 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-regions-data-sync.yml@refs/heads/main' && " +
            "vars.REGIONS_DATA_SYNC_ENABLED == 'true'")
        $workflowText | Should -Match '(?m)^concurrency:\r?\n  group: repository-management-regions-data-sync\r?\n  cancel-in-progress: false$'
        $workflowText | Should -Match '(?m)^  id-token: write$'
        ([regex]::Matches($workflowText, '(?m)^    environment: avm$')).Count | Should -Be 2
        $workflowText | Should -Not -Match '(?m)^    environment: regions-update-data$'
    }

    It 'uses the repo-sync collection identity and narrowly scoped publication token' {
        $workflowText | Should -Match '(?ms)client-id: \$\{\{ vars\.ARM_BACKEND_CLIENT_ID \}\}\s+tenant-id: \$\{\{ vars\.ARM_BACKEND_TENANT_ID \}\}\s+subscription-id: \$\{\{ vars\.ARM_BACKEND_SUBSCRIPTION_ID \}\}'
        $workflowText | Should -Match 'ARM_BACKEND_SUBSCRIPTION_ID/locations\?api-version=2023-07-01'
        $workflowText | Should -Match '(?ms)repositories: terraform-azurerm-avm-utl-regions\s+permission-contents: write\s+permission-pull-requests: write'
        $workflowText | Should -Match '(?m)^\s{10}AVM_APP_SLUG:\s*\$\{\{\s*steps\.app-token\.outputs\.app-slug\s*\}\}\s*$'
        $workflowText | Should -Match "gh api repos/Azure/terraform-azurerm-avm-utl-regions --jq '.default_branch'"
        $workflowText | Should -Match 'git check-ref-format --branch \$branch'
        $workflowText | Should -Not -Match 'secrets: inherit'
    }

    It 'limits artifacts and publishing changes to the locations cache' {
        $workflowText | Should -Match '(?ms)name: regions-locations-data\s+path: regions/modules/cached-data/locations\.tf\.json'
        $workflowText | Should -Match "changedPaths\[0\] -cne 'modules/cached-data/locations.tf.json'"
        $workflowText | Should -Match "git add -- 'modules/cached-data/locations.tf.json'"
        $publishStep.run | Should -Not -Match 'gh pr close|--delete-branch'
    }

    It 'does not interpolate expressions into PowerShell run bodies' {
        $runBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $runBlocks) {
            $match.Groups['body'].Value | Should -Not -Match '\$\{\{'
        }
    }

    Describe 'Regions data sync workflow execution' {
        BeforeAll {
            function az { param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments) }
            function jd { param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments) }
            function gh { param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments) }
            $script:subscriptionId = '00000000-0000-0000-0000-000000000001'
            $script:savedEnvironment = @{}
            foreach ($name in @('ARM_BACKEND_SUBSCRIPTION_ID', 'GITHUB_OUTPUT', 'AVM_APP_SLUG', 'BASE_BRANCH')) {
                $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
        }

        AfterAll {
            foreach ($name in $script:savedEnvironment.Keys) {
                $value = $script:savedEnvironment[$name]
                if ($null -eq $value) { $value = [NullString]::Value }
                [Environment]::SetEnvironmentVariable($name, $value, 'Process')
            }
        }

        BeforeEach {
            $env:ARM_BACKEND_SUBSCRIPTION_ID = $script:subscriptionId
            $env:GITHUB_OUTPUT = Join-Path $TestDrive 'output.txt'
            $env:AVM_APP_SLUG = 'azure-verified-modules'
            $env:BASE_BRANCH = 'main'
            $script:cachePath = Join-Path $TestDrive 'modules' 'cached-data' 'locations.tf.json'
            $null = New-Item -ItemType Directory -Path (Split-Path $script:cachePath) -Force
            Set-Content -LiteralPath $script:cachePath -Value '{"original":true}' -NoNewline
            Mock az {
                '{"value":[{"name":"westus"},{"name":"eastus"}]}'
            }
            Mock jd { $global:LASTEXITCODE = 0 }
            Mock gh { throw 'Unexpected GitHub operation.' }
        }

        It 'queries the exported repo-sync subscription and writes sorted locations' {
            $collectionStep.env.ARM_BACKEND_SUBSCRIPTION_ID | Should -BeExactly '${{ vars.ARM_BACKEND_SUBSCRIPTION_ID }}'
            Push-Location $TestDrive
            try { & ([scriptblock]::Create($collectionStep.run)) }
            finally { Pop-Location }

            Should -Invoke az -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains "/subscriptions/$script:subscriptionId/locations?api-version=2023-07-01"
            }
            $cache = Get-Content -LiteralPath $script:cachePath -Raw | ConvertFrom-Json
            $cache.locals.locations_cached.value.name | Should -Be @('eastus', 'westus')
        }

        It 'rejects a missing subscription without querying Azure or replacing the cache' {
            $env:ARM_BACKEND_SUBSCRIPTION_ID = ''
            Push-Location $TestDrive
            try {
                { & ([scriptblock]::Create($collectionStep.run)) } | Should -Throw '*source subscription*'
            }
            finally { Pop-Location }
            Should -Invoke az -Times 0
            Get-Content -LiteralPath $script:cachePath -Raw | Should -BeExactly '{"original":true}'
        }

        It 'rejects an empty Azure response without replacing the cache' {
            Mock az { '{"value":[]}' }
            Push-Location $TestDrive
            try {
                { & ([scriptblock]::Create($collectionStep.run)) } | Should -Throw '*nonempty locations collection*'
            }
            finally { Pop-Location }
            Get-Content -LiteralPath $script:cachePath -Raw | Should -BeExactly '{"original":true}'
        }

        It 'accepts a changed JSON comparison without failing the Actions step' {
            Mock jd { $global:LASTEXITCODE = 1 }
            Push-Location $TestDrive
            try { & ([scriptblock]::Create($compareStep.run)) }
            finally { Pop-Location }
            $LASTEXITCODE | Should -Be 0
            Get-Content -LiteralPath $env:GITHUB_OUTPUT | Should -BeExactly 'changed=true'
        }

        It 'fails a broken comparison instead of publishing it' {
            Mock jd { $global:LASTEXITCODE = 2 }
            Push-Location $TestDrive
            try {
                { & ([scriptblock]::Create($compareStep.run)) } | Should -Throw '*jd failed*'
            }
            finally { Pop-Location }
        }

        It 'leaves an existing regions update untouched before any publication work' {
            Mock gh { '[{"headRefName":"update31295078951"}]' } -ParameterFilter {
                $Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'list'
            }
            { & ([scriptblock]::Create($publishStep.run)) } | Should -Not -Throw
            Should -Invoke gh -Times 1 -Exactly
        }

        It 'installs and invokes the authoring module instead of a nonexistent target launcher' {
            $steps = @($definition.jobs.publish.steps)
            $installStep = $steps | Where-Object name -EQ 'Install AVM authoring for generated-data validation'
            $steps.IndexOf($installStep) | Should -BeLessThan $steps.IndexOf($publishStep)
            $installStep.run | Should -Match 'Install-PSResource -Name Avm.Authoring'
            $publishStep.run | Should -Match '(?m)^Import-Module Avm.Authoring -Force -ErrorAction Stop$'
            $publishStep.run | Should -Match '(?m)^avm pre-commit$'
            $publishStep.run | Should -Not -Match '\./avm'
        }
    }
}
