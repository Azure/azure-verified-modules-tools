function Test-AvmBicepConventionWorkflow {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        $Scope,

        # Located and parsed workflow from Get-AvmBicepConventionWorkflowInput.
        [Parameter(Mandatory)]
        $WorkflowInput
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $root = $Scope.RepositoryRoot
    $filename = $WorkflowInput.FileName
    $path = $WorkflowInput.Path
    if (@($WorkflowInput.Issues).Count -gt 0) {
        foreach ($issue in @($WorkflowInput.Issues)) {
            $issues.Add($issue)
        }
        return $issues.ToArray()
    }
    $workflow = $WorkflowInput.Workflow

    $environment = if ($workflow.Contains('env') -and
        $workflow['env'] -is [System.Collections.IDictionary]) { $workflow['env'] } else { @{} }
    foreach ($entry in @(
            @{ Name = 'workflowPath'; Value = ".github/workflows/$filename"; Code = 'avm.bicep.workflow-path' }
            @{ Name = 'modulePath'; Value = $Scope.ModuleRelativePath; Code = 'avm.bicep.workflow-module-path' }
        )) {
        if (-not $environment.Contains($entry.Name)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                        -Code 'avm.bicep.workflow-env' -Message "Workflow env.$($entry.Name) is required."))
        }
        elseif ($environment[$entry.Name] -isnot [string] -or
            $environment[$entry.Name] -cne $entry.Value) {
            $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                        -Code $entry.Code -Message "Workflow env.$($entry.Name) must be '$($entry.Value)'."))
        }
    }

    $events = if ($workflow.Contains('on') -and
        $workflow['on'] -is [System.Collections.IDictionary]) { $workflow['on'] } else { @{} }
    if (@($events.Keys | Where-Object { $_ -cnotin @('workflow_dispatch', 'push') }).Count -gt 0) {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                    -Code 'avm.bicep.workflow-trigger' `
                    -Message 'Only workflow_dispatch and push may trigger this module workflow.'))
    }
    $dispatch = if ($events.Contains('workflow_dispatch') -and
        $events['workflow_dispatch'] -is [System.Collections.IDictionary]) {
        $events['workflow_dispatch']
    }
    else { @{} }
    $inputs = if ($dispatch.Contains('inputs') -and
        $dispatch['inputs'] -is [System.Collections.IDictionary]) { $dispatch['inputs'] } else { @{} }
    foreach ($name in @('customLocation', 'staticValidation', 'deploymentValidation', 'removeDeployment')) {
        if (-not $inputs.Contains($name) -or $inputs[$name] -isnot [System.Collections.IDictionary]) {
            $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                        -Code 'avm.bicep.workflow-dispatch' -Message "Workflow dispatch input '$name' is required."))
            continue
        }
        if ($name -in @('staticValidation', 'deploymentValidation') -and
            (-not $inputs[$name].Contains('default') -or
            $inputs[$name]['default'] -isnot [bool] -or
            $inputs[$name]['default'] -ne $true)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                        -Code "avm.bicep.workflow-$name-default" `
                        -Message "Workflow dispatch input '$name' must default to true."))
        }
        if ($name -ceq 'customLocation' -and $inputs[$name].Contains('default')) {
            $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                        -Code 'avm.bicep.workflow-custom-location' `
                        -Message "Workflow dispatch input 'customLocation' must not have a default."))
        }
    }

    $push = if ($events.Contains('push') -and
        $events['push'] -is [System.Collections.IDictionary]) { $events['push'] } else { @{} }
    if (@($push.Keys | Where-Object { $_ -cnotin @('branches', 'paths') }).Count -gt 0) {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                    -Code 'avm.bicep.workflow-push-options' `
                    -Message 'Push triggers may contain only branches and paths; tags and additional filters bypass the main/path checks.'))
    }
    $branches = @()
    if ($push.Contains('branches')) {
        $branches = @($push['branches'])
    }
    if ($branches.Count -ne 1 -or $branches[0] -isnot [string] -or $branches[0] -cne 'main') {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                    -Code 'avm.bicep.workflow-push-branches' `
                    -Message 'Only the main branch may trigger this module workflow on push.'))
    }

    $paths = @()
    if ($push.Contains('paths')) {
        $paths = @($push['paths'])
    }
    $expected = @(
        ".github/workflows/$filename"
        "$($Scope.ModuleRelativePath)/**"
        '!*/**/README.md'
        '!avm/**/metadata.json'
    )
    $missing = @($expected | Where-Object { $paths -cnotcontains $_ })
    $excess = @($paths | Where-Object { $_ -isnot [string] -or $_ -cnotin $expected })
    if ($missing.Count -gt 0) {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                    -Code 'avm.bicep.workflow-push-paths-missing' `
                    -Message ("Push path filters must contain {0}." -f ($missing -join ', '))))
    }
    if ($paths.Count -ne $expected.Count -or $excess.Count -gt 0) {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                    -Code 'avm.bicep.workflow-push-paths-excess' `
                    -Message 'Push path filters must contain only the four canonical patterns, with no duplicates.'))
    }
    if ($paths.Count -eq 0 -or $paths[-1] -cne '!avm/**/metadata.json') {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                    -Code 'avm.bicep.workflow-push-metadata-last' `
                    -Message 'The metadata.json exclusion must be the last push path filter.'))
    }
    if ($paths.Count -eq $expected.Count -and
        ($paths[0] -cne $expected[0] -or $paths[1] -cne $expected[1] -or
        $paths[2] -cne $expected[2] -or $paths[3] -cne $expected[3])) {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                    -Code 'avm.bicep.workflow-push-paths-order' `
                    -Message 'Push path filters must follow the canonical order so exclusions cannot be overridden.'))
    }

    $jobs = if ($workflow.Contains('jobs') -and
        $workflow['jobs'] -is [System.Collections.IDictionary]) { $workflow['jobs'] } else { @{} }
    $initialize = if ($jobs.Contains('job_initialize_pipeline') -and
        $jobs['job_initialize_pipeline'] -is [System.Collections.IDictionary]) {
        $jobs['job_initialize_pipeline']
    }
    else { @{} }
    $condition = if ($initialize.Contains('if')) { $initialize['if'] } else { $null }
    $expression = if ($condition -is [string]) { $condition.Trim() } else { '' }
    if ($expression.StartsWith('${{', [System.StringComparison]::Ordinal) -and
        $expression.EndsWith('}}', [System.StringComparison]::Ordinal)) {
        $expression = $expression.Substring(3, $expression.Length - 5).Trim()
    }
    if ($expression -cnotmatch "^\s*!cancelled\(\)\s*&&\s*!\(\s*github\.repository\s*!=\s*'Azure/bicep-registry-modules'\s*&&\s*github\.event_name\s*!=\s*'workflow_dispatch'\s*\)\s*$") {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $path `
                    -Code 'avm.bicep.workflow-condition' `
                    -Message 'job_initialize_pipeline must use the canonical cancellation and upstream-only condition without additional alternatives.'))
    }

    return $issues.ToArray()
}
