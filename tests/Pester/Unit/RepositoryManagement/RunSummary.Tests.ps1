BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    . (Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'lib' 'RunSummary.ps1')
}

Describe 'Format-AvmRunSummaryList' {
    It 'returns the empty text when there is nothing to list' {
        Format-AvmRunSummaryList -Values @() | Should -Be 'none'
        Format-AvmRunSummaryList -Values @($null, ' ') -Empty 'nobody' | Should -Be 'nobody'
    }

    It 'joins the values and says how many were left out' {
        Format-AvmRunSummaryList -Values @('a', 'b', 'c') | Should -Be 'a, b, c'
        Format-AvmRunSummaryList -Values @('a', 'b', 'c') -Limit 2 | Should -Be 'a, b and 1 more'
    }

    It 'formats values as code spans that cannot break a Markdown table' {
        Format-AvmRunSummaryList -Values @('a|b', 'c`d') -AsCode | Should -Be '`a\|b`, `c''d`'
    }
}

Describe 'Write-AvmRunSummary' {
    BeforeEach {
        $script:previousSummary = $env:GITHUB_STEP_SUMMARY
        $script:summaryPath = Join-Path $TestDrive 'summary.md'
        Remove-Item -LiteralPath $script:summaryPath -ErrorAction SilentlyContinue
        $env:GITHUB_STEP_SUMMARY = $script:summaryPath
    }

    AfterEach {
        $env:GITHUB_STEP_SUMMARY = $script:previousSummary
    }

    It 'logs the overview and detail lines' {
        $log = Write-AvmRunSummary -Title 'Routing' -Overview '2 checked' -LogLines @('first detail') 6>&1 | Out-String
        $log | Should -Match 'Routing summary: 2 checked'
        $log | Should -Match '(?m)^  first detail'
    }

    It 'writes the overview, table and failures to the job summary' {
        Write-AvmRunSummary -Title 'Routing' -Overview '2 checked' -TableHeaders @('Item', 'Result') `
            -TableRows @(, [string[]]@('one', 'done')) -Failures @("first line`nsecond line") 6>$null
        $summary = Get-Content -Raw -LiteralPath $script:summaryPath
        $summary | Should -Match '(?m)^### Routing\r?$'
        $summary | Should -Match '(?m)^2 checked\r?$'
        $summary | Should -Match '(?m)^\| Item \| Result \|\r?$'
        $summary | Should -Match '(?m)^\| --- \| --- \|\r?$'
        $summary | Should -Match '(?m)^\| one \| done \|\r?$'
        $summary | Should -Match '(?m)^- `first line second line`\r?$'
    }

    It 'leaves out the table when there are no rows' {
        Write-AvmRunSummary -Title 'Routing' -Overview '0 checked' -TableHeaders @('Item') 6>$null
        Get-Content -Raw -LiteralPath $script:summaryPath | Should -Not -Match '\|'
    }

    It 'only logs outside GitHub Actions' {
        $env:GITHUB_STEP_SUMMARY = ''
        Write-AvmRunSummary -Title 'Routing' -Overview '0 checked' 6>$null
        Test-Path -LiteralPath $script:summaryPath | Should -BeFalse
    }

    It 'still writes the job summary when the caller runs with WhatIf' {
        function Invoke-AvmRunSummaryDryRunCaller {
            [CmdletBinding(SupportsShouldProcess)]
            param()
            Write-AvmRunSummary -Title 'Routing' -Overview '1 checked' -DryRun
        }

        Invoke-AvmRunSummaryDryRunCaller -WhatIf 6>$null

        Get-Content -Raw -LiteralPath $script:summaryPath | Should -Match '(?m)^### Routing \(dry run, nothing changed\)\r?$'
    }
}
