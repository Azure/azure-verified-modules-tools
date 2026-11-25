#Requires -Version 7.4

function ConvertTo-AvmReportFlag {
    param([AllowNull()] [object] $Value, [string] $Name)
    if ($Value -cnotin @('true', 'false')) {
        throw [IO.InvalidDataException]::new("$Name must be exactly true or false.")
    }
    return $Value -ceq 'true'
}

function ConvertFrom-AvmReportArray {
    param([AllowNull()] [string] $Json, [string] $Name)
    $value = ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate -ErrorAction Stop
    if ($value -isnot [array]) {
        throw [IO.InvalidDataException]::new("$Name must be a JSON array.")
    }
    return ,$value
}

function Get-AvmWorkflowReportState {
    [CmdletBinding()]
    param(
        [ValidateSet('bicep', 'terraform')] [string] $Ecosystem,
        [System.Collections.IDictionary] $Results,
        [bool] $RequireE2e,
        [string] $EventName,
        [string] $Repository
    )

    $state = [pscustomobject]@{
        Applicable = $false
        HasRequired = $false
        HasOptional = $false
        Authorized = $false
        OptionalSelected = $false
        Failures = [Collections.Generic.List[string]]::new()
    }
    $jobs = if ($Ecosystem -ceq 'terraform') {
        @('bootstrap', 'subscriptions', 'unit-test', 'pr-check', 'integration-test',
            'discover-examples', 'select-e2e-tests', 'e2e-test')
    }
    else {
        @('initialize', 'check')
        if ($Results.Contains('check-fork')) { 'check-fork' }
    }
    foreach ($name in $jobs) {
        if ($Results[$name] -isnot [System.Collections.IDictionary] -or
            $Results[$name]['result'] -cnotin @('success', 'failure', 'cancelled', 'skipped')) {
            throw [IO.InvalidDataException]::new("Missing or invalid job result: $name.")
        }
    }
    if ($EventName -cnotin @('pull_request', 'workflow_dispatch')) {
        $state.Failures.Add('Merge gates support pull_request and workflow_dispatch only; merge queues are not supported.')
        return $state
    }

    if ($Ecosystem -ceq 'terraform') {
        foreach ($name in @('bootstrap', 'subscriptions', 'unit-test', 'pr-check', 'integration-test')) {
            if ($Results[$name]['result'] -cne 'success') {
                $state.Failures.Add("Required validation job '$name' did not pass ($($Results[$name]['result'])). Fork contributions require a same-repository release-branch handoff for authenticated checks.")
            }
        }
        if ($Repository -cmatch '/terraform-azurerm-avm-template$') { return $state }
        $discovery = $Results['discover-examples']
        if ($discovery['result'] -cne 'success') {
            $state.Failures.Add('E2E example discovery did not pass.')
            return $state
        }
        $outputs = $discovery['outputs']
        $state.HasRequired = (ConvertFrom-AvmReportArray $outputs['requiredExamples'] 'requiredExamples').Count -gt 0
        $state.HasOptional = (ConvertFrom-AvmReportArray $outputs['optionalExamples'] 'optionalExamples').Count -gt 0
        $state.Authorized = ConvertTo-AvmReportFlag $outputs['runRequired'] 'runRequired'
        $state.OptionalSelected = ConvertTo-AvmReportFlag $outputs['runOptional'] 'runOptional'
        $state.Applicable = $true
        if ($state.Authorized) {
            if ($Results['select-e2e-tests']['result'] -cne 'success') {
                $state.Failures.Add('E2E test and subscription selection did not pass.')
            }
            elseif ((ConvertFrom-AvmReportArray $Results['select-e2e-tests']['outputs']['deploymentMatrix'] 'deploymentMatrix').Count -gt 0 -and
                $Results['e2e-test']['result'] -cne 'success') {
                $state.Failures.Add("Selected E2E tests did not pass ($($Results['e2e-test']['result'])).")
            }
        }
    }
    else {
        if ($Results['initialize']['result'] -cne 'success') {
            $state.Failures.Add('Bicep initialization did not succeed.')
            return $state
        }
        $outputs = $Results['initialize']['outputs']
        $hasModules = ConvertTo-AvmReportFlag $outputs['hasModules'] 'hasModules'
        if ($RequireE2e) {
            $state.HasRequired = ConvertTo-AvmReportFlag $outputs['hasRequiredModules'] 'hasRequiredModules'
            $state.HasOptional = ConvertTo-AvmReportFlag $outputs['hasOptionalModules'] 'hasOptionalModules'
            $state.Authorized = ConvertTo-AvmReportFlag $outputs['requiredRequested'] 'requiredRequested'
            $state.OptionalSelected = ConvertTo-AvmReportFlag $outputs['optionalRequested'] 'optionalRequested'
            $ignored = ConvertFrom-AvmReportArray $outputs['requiredErrors'] 'requiredErrors'
            if ($ignored.Count -gt 0) {
                $state.Failures.Add("Required E2E scenarios are ignored: $($outputs['requiredErrors'])")
            }
        }
        $state.Applicable = $hasModules -and $RequireE2e
        if ($hasModules) {
            $checkJobs = @('check')
            if ($Results.Contains('check-fork')) { $checkJobs += 'check-fork' }
            $selected = @($checkJobs | Where-Object { $Results[$_]['result'] -cne 'skipped' })
            if ($selected.Count -ne 1 -or $Results[$selected[0]]['result'] -cne 'success') {
                $state.Failures.Add('Bicep module checks did not succeed (static, unit, or selected E2E tests).')
            }
        }
    }
    if ($state.OptionalSelected -and -not $state.Authorized) {
        throw [IO.InvalidDataException]::new('Optional E2E selection requires required E2E authorization.')
    }
    return $state
}

function Write-AvmReportAnnotation {
    param([ValidateSet('error', 'warning')] [string] $Level, [string] $Message)
    $escaped = $Message.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    Write-Host "::${Level}::$escaped"
}

function Invoke-AvmWorkflowReport {
    <#
    .SYNOPSIS
        Evaluate AVM check results and publish shared workflow and PR feedback.
    .DESCRIPTION
        Runs in the trusted Tools action's Avm.Authoring module scope. Keeps
        ecosystem gate policy separate from shared summaries and sticky comments.
        Forks never call the comment API. Live head and label checks prevent stale
        comments; only bot-owned ecosystem markers are updated. HTTP 403 leaves
        visible feedback without changing the gate; other API failures propagate.
    .PARAMETER Ecosystem
        Bicep or Terraform gate policy.
    .PARAMETER ResultsJson
        Serialized GitHub Actions needs context.
    .PARAMETER RequireE2e
        Exact true or false Bicep deployment-enforcement flag.
    .PARAMETER Event
        Parsed event payload; defaults to GITHUB_EVENT_PATH.
    .PARAMETER EventName
        GitHub event name.
    .PARAMETER Repository
        Upstream owner/name.
    .PARAMETER SummaryPath
        GitHub Actions summary file.
    .PARAMETER ServerUrl
        GitHub server URL used in the run link.
    .PARAMETER RunId
        Current workflow run identifier.
    .PARAMETER WhatIf
        Report the gate without changing PR comments.
    .PARAMETER Confirm
        Request confirmation before changing a PR comment.
    .EXAMPLE
        Invoke-AvmWorkflowReport -Ecosystem terraform -ResultsJson $env:REPORT_RESULTS -WhatIf
    .OUTPUTS
        PSCustomObject with Passed, RequiredLabelMissing, and CommentPublished.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('bicep', 'terraform')] [string] $Ecosystem,
        [Parameter(Mandatory)] [string] $ResultsJson,
        [ValidateSet('true', 'false', IgnoreCase = $false)] [string] $RequireE2e = 'true',
        [System.Collections.IDictionary] $Event,
        [string] $EventName = $env:GITHUB_EVENT_NAME,
        [string] $Repository = $env:GITHUB_REPOSITORY,
        [string] $SummaryPath = $env:GITHUB_STEP_SUMMARY,
        [string] $ServerUrl = $env:GITHUB_SERVER_URL,
        [string] $RunId = $env:GITHUB_RUN_ID
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $Ecosystem = $Ecosystem.ToLowerInvariant()
    if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') {
        throw [ArgumentException]::new('Repository must be an owner/name pair.')
    }
    $results = ConvertFrom-Json -InputObject $ResultsJson -AsHashtable -ErrorAction Stop
    if ($results -isnot [System.Collections.IDictionary]) {
        throw [IO.InvalidDataException]::new('Workflow results must be a JSON object.')
    }
    $state = Get-AvmWorkflowReportState -Ecosystem $Ecosystem -Results $results `
        -RequireE2e ($RequireE2e -ceq 'true') -EventName $EventName -Repository $Repository
    $requiredLabel = 'PR: Run Required E2E Tests'
    $allLabel = 'PR: Run All E2E Tests'
    $missing = $state.Applicable -and $state.HasRequired -and -not $state.Authorized
    $noRequired = $state.Applicable -and -not $state.HasRequired
    $labelInstructions = "Add ``$requiredLabel`` to run required scenarios only, or ``$allLabel`` to run required and optional scenarios."
    $forkInstructions = 'Labels on a fork do not authorize cloud tests. Ask a maintainer for an authorized same-repository release-branch handoff.'
    $feedback = [Collections.Generic.List[string]]::new()
    if ($missing) {
        $state.Failures.Add("Required E2E tests must run and pass before merging. $labelInstructions $forkInstructions")
        $feedback.Add('## Action required: authorize E2E tests')
        $feedback.Add('Merging is blocked: existing required E2E tests must run and pass.')
    }
    elseif ($noRequired) {
        $feedback.Add('## E2E scenario selection')
        $feedback.Add('Warning: no runnable required E2E scenarios were discovered. Their absence does not currently block merging.')
        Write-AvmReportAnnotation -Level warning -Message 'No required E2E scenarios found; optional scenarios need the All E2E label.'
        if (-not $state.HasOptional) {
            $feedback.Add('No runnable E2E examples were discovered. Labels cannot run examples that do not exist.')
        }
        elseif ($state.OptionalSelected) {
            $feedback.Add('All existing E2E scenarios were selected. Check their job results; selection does not mean validation passed.')
        }
        else {
            $feedback.Add("No E2E deployment tests were selected. ``$requiredLabel`` selects no tests here; add ``$allLabel`` to run optional scenarios.")
        }
    }
    else {
        $feedback.Add('## E2E label requirement satisfied')
        $feedback.Add('No E2E label action is needed for this run. This does not mean validation has passed.')
    }
    if ($missing -or $noRequired) {
        $feedback.Add($labelInstructions)
        $feedback.Add('Open PRs early and add deployment labels when ready to avoid unnecessary cloud cost and runtime.')
        $feedback.Add($forkInstructions)
    }
    $summary = [Collections.Generic.List[string]]::new()
    $summary.Add("## $Ecosystem check status")
    $summary.Add($(if ($state.Failures.Count -eq 0) { 'Applicable merge checks passed.' } else { 'Merging is blocked.' }))
    foreach ($failure in $state.Failures) {
        $summary.Add("- $failure")
        Write-AvmReportAnnotation -Level error -Message $failure
    }
    if ($state.Applicable) { $summary.Add($feedback -join "`n`n") }
    if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
        throw [InvalidOperationException]::new('The GitHub step summary file is not configured.')
    }
    if (-not $WhatIfPreference) {
        [IO.File]::AppendAllText($SummaryPath, ($summary -join "`n`n") + "`n", [Text.UTF8Encoding]::new($false))
    }
    $report = [pscustomobject]@{ Passed = $state.Failures.Count -eq 0; RequiredLabelMissing = $missing; CommentPublished = $false }
    if ($EventName -cne 'pull_request' -or -not $state.Applicable -or $WhatIfPreference) { return $report }
    if ($null -eq $Event) { $Event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json -AsHashtable }
    $pr = $Event['pull_request']
    if ($pr['head']['repo']['full_name'] -cne $Repository) {
        Write-AvmReportAnnotation -Level warning -Message 'Fork feedback is available in the run summary; a read-only fork token cannot publish PR comments.'
        return $report
    }
    $number = $pr['number']
    if ($number -isnot [long] -and $number -isnot [int] -or $number -lt 1 -or
        [string]::IsNullOrWhiteSpace($pr['head']['sha'])) {
        throw [IO.InvalidDataException]::new('The pull request number and head are missing or invalid.')
    }
    $marker = if ($Ecosystem -ceq 'terraform') { '<!-- avm-terraform-e2e-label -->' }
    else { '<!-- avm-bicep-required-e2e-label-feedback -->' }
    try {
        $current = Invoke-AvmGitHubApi -Endpoint "repos/$Repository/pulls/$number"
        $snapshotLabels = @($pr['labels'] | ForEach-Object { $_['name'] })
        $liveLabels = @($current['labels'] | ForEach-Object { $_['name'] })
        if ($current['head']['sha'] -cne $pr['head']['sha'] -or
            @(@($requiredLabel, $allLabel) | Where-Object { ($snapshotLabels -ccontains $_) -ne ($liveLabels -ccontains $_) }).Count -gt 0) {
            Write-AvmReportAnnotation -Level warning -Message 'Skipped stale E2E feedback because the PR head or E2E labels changed.'
            return $report
        }
        $previous = $null
        $page = 1
        do {
            $comments = @(Invoke-AvmGitHubApi -Endpoint "repos/$Repository/issues/$number/comments?per_page=100&page=$page")
            $previous = $comments | Where-Object {
                $_['user']['login'] -ceq 'github-actions[bot]' -and $_['body'] -is [string] -and $_['body'].StartsWith($marker, [StringComparison]::Ordinal)
            } | Select-Object -First 1
            $page++
        } while ($null -eq $previous -and $comments.Count -eq 100)
        $body = "$marker`n`n$($feedback -join "`n`n")`n`n[View PR-check run]($ServerUrl/$Repository/actions/runs/$RunId)"
        if ($null -ne $previous) {
            if ($previous['body'] -cne $body -and $PSCmdlet.ShouldProcess("$Repository comment $($previous['id'])", 'Update E2E feedback')) {
                $null = Invoke-AvmGitHubApi -Endpoint "repos/$Repository/issues/comments/$($previous['id'])" -Method PATCH -Body @{ body = $body }
                $report.CommentPublished = $true
            }
        }
        elseif (($missing -or $noRequired) -and $PSCmdlet.ShouldProcess("$Repository PR $number", 'Create E2E feedback')) {
            $null = Invoke-AvmGitHubApi -Endpoint "repos/$Repository/issues/$number/comments" -Method POST -Body @{ body = $body }
            $report.CommentPublished = $true
        }
    }
    catch [AvmGitHubException] {
        if ($_.Exception.StatusCode -ne 403) { throw }
        $message = 'GitHub denied permission to publish E2E feedback (HTTP 403). See the run summary; the merge gate is unchanged.'
        Write-AvmReportAnnotation -Level warning -Message $message
        [IO.File]::AppendAllText($SummaryPath, "`n$message`n", [Text.UTF8Encoding]::new($false))
    }
    return $report
}
