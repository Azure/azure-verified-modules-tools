#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'terraform-module reusable workflow' {
    BeforeAll {
        $script:workflowPath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'terraform-module.yml'
        $script:workflow = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'passes the non-secret subscription ID as a job output without masking it' {
        $script:workflow | Should -Match '"subscriptionId=\$\(\$chosen\.id\)"'
        $script:workflow | Should -Not -Match '::add-mask::'
    }

    It 'publishes the full shuffled subscription list for the e2e fan-out' {
        $script:workflow | Should -Match 'subscriptionIds:\s*\$\{\{ steps\.pick\.outputs\.subscriptionIds \}\}'
        $script:workflow | Should -Match '"subscriptionIds=\$ordered"'
    }

    It 'discovers e2e examples with the machine-readable list surface' {
        $script:workflow | Should -Match 'avm test e2e --list'
        $script:workflow | Should -Match 'examples:\s*\$\{\{ steps\.list\.outputs\.examples \}\}'
        $script:workflow | Should -Match 'hasExamples:\s*\$\{\{ steps\.list\.outputs\.hasExamples \}\}'
    }

    It 'fans e2e out across a per-example matrix that does not fail fast' {
        $script:workflow | Should -Match 'fail-fast:\s*false'
        $script:workflow | Should -Match 'example:\s*\$\{\{ fromJson\(needs\.discover-examples\.outputs\.examples\) \}\}'
        $script:workflow | Should -Match 'name:\s*End-to-end tests \(\$\{\{ matrix\.example \}\}\)'
        $script:workflow | Should -Match 'avm test e2e --example'
    }

    It 'skips the e2e matrix when no runnable examples were discovered' {
        $script:workflow | Should -Match "needs\.discover-examples\.outputs\.hasExamples == 'true'"
    }

    It 'keeps the e2e environment static so one approval releases every matrix leg' {
        $script:workflow | Should -Match 'environment:\s*examples-test'
        $script:workflow | Should -Not -Match 'environment:\s*.*\$\{\{\s*matrix\.'
    }

    It 'round-robins the subscription across matrix legs using strategy.job-index' {
        $script:workflow | Should -Match 'JOB_INDEX:\s*\$\{\{ strategy\.job-index \}\}'
        $script:workflow | Should -Match '\$subs\[\$index % \$subs\.Count\]'
    }

    It 'keeps the single-subscription fallback path for the matrix legs' {
        $script:workflow | Should -Match 'FALLBACK_SUBSCRIPTION_ID:\s*\$\{\{ needs\.subscriptions\.outputs\.subscriptionId \}\}'
    }

    It 'no longer lists per-example e2e targeting as a divergence' {
        $script:workflow | Should -Not -Match 'has no per-example targeting'
    }
}

Describe 'CI workflow' {
    BeforeAll {
        $script:ciPath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'ci.yml'
        $script:ci = Get-Content -LiteralPath $script:ciPath -Raw
    }

    It 'authenticates tflint plugin downloads so the shared macOS runner egress does not hit the GitHub API rate limit' {
        $script:ci | Should -Match 'GITHUB_TOKEN:\s*\$\{\{ github\.token \}\}'
    }
}