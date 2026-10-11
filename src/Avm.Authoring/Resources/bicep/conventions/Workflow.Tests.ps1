#Requires -Version 7.4
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'environment', Justification = 'Pester BeforeAll shares this value with It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'inputs', Justification = 'Pester BeforeAll shares this value with It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'paths', Justification = 'Pester BeforeAll shares this value with It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'expectedPaths', Justification = 'Pester BeforeAll shares this value with It blocks.')]
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$cases = @($Convention.Workflows | ForEach-Object {
        @{ Scope = $_.Scope; WorkflowInput = $_.Input; Label = $_.Scope.ModuleRelativePath; IssuePath = $_.Input.Path; IssueRoot = $_.Scope.RepositoryRoot }
    })
$Convention.NativeWorkflowExpected = 0

Describe 'Bicep workflow: <Label>' -ForEach $cases {
    $Convention.NativeWorkflowExpected++
    $inputCode = if ($WorkflowInput.Issues.Count -gt 0) { $WorkflowInput.Issues[0].Code } else { 'avm.bicep.workflow-file' }
    It 'loads a regular, exact-case workflow as YAML' -Tag $inputCode {
        @($WorkflowInput.Issues) | Should -HaveCount 0 -Because (@($WorkflowInput.Issues | ForEach-Object Message) -join '; ')
        $WorkflowInput.Workflow | Should -BeOfType ([System.Collections.IDictionary])
    }
    if ($WorkflowInput.Issues.Count -eq 0 -and $WorkflowInput.Workflow -is [System.Collections.IDictionary]) {
        $Convention.NativeWorkflowExpected += 19
        BeforeAll {
            $workflow = $WorkflowInput.Workflow
            $environment = if ($workflow['env'] -is [System.Collections.IDictionary]) { $workflow['env'] } else { @{} }
            $events = if ($workflow['on'] -is [System.Collections.IDictionary]) { $workflow['on'] } else { @{} }
            $dispatch = if ($events['workflow_dispatch'] -is [System.Collections.IDictionary]) { $events['workflow_dispatch'] } else { @{} }
            $inputs = if ($dispatch['inputs'] -is [System.Collections.IDictionary]) { $dispatch['inputs'] } else { @{} }
            $push = if ($events['push'] -is [System.Collections.IDictionary]) { $events['push'] } else { @{} }
            $paths = @(if ($push.Contains('paths')) { $push['paths'] })
            $expectedPaths = @(".github/workflows/$($WorkflowInput.FileName)", "$($Scope.ModuleRelativePath)/**", '!*/**/README.md', '!avm/**/metadata.json')
        }
        It 'declares env.<Name>' -ForEach @(@{ Name = 'workflowPath' }, @{ Name = 'modulePath' }) -Tag 'avm.bicep.workflow-env' {
            $environment.Contains($Name) | Should -BeTrue
        }
        It 'sets the canonical workflow path' -Tag 'avm.bicep.workflow-path' {
            $environment['workflowPath'] | Should -BeOfType ([string])
            $environment['workflowPath'] | Should -BeExactly ".github/workflows/$($WorkflowInput.FileName)"
        }
        It 'sets the canonical module path' -Tag 'avm.bicep.workflow-module-path' {
            $environment['modulePath'] | Should -BeOfType ([string])
            $environment['modulePath'] | Should -BeExactly $Scope.ModuleRelativePath
        }
        It 'permits only manual and push triggers' -Tag 'avm.bicep.workflow-trigger' {
            @($events.psbase.Keys | Where-Object { $_ -cnotin @('workflow_dispatch', 'push') }) | Should -HaveCount 0
        }
        It 'declares dispatch input <Name>' -ForEach @(
            @{ Name = 'customLocation' }, @{ Name = 'staticValidation' },
            @{ Name = 'deploymentValidation' }, @{ Name = 'removeDeployment' }
        ) -Tag 'avm.bicep.workflow-dispatch' {
            $inputs[$Name] | Should -BeOfType ([System.Collections.IDictionary])
        }
        It 'enables static validation by default' -Tag 'avm.bicep.workflow-staticValidation-default' {
            $inputs['staticValidation'] | Should -BeOfType ([System.Collections.IDictionary])
            $inputs['staticValidation']['default'] | Should -BeOfType ([bool])
            $inputs['staticValidation']['default'] | Should -BeTrue
        }
        It 'enables deployment validation by default' -Tag 'avm.bicep.workflow-deploymentValidation-default' {
            $inputs['deploymentValidation'] | Should -BeOfType ([System.Collections.IDictionary])
            $inputs['deploymentValidation']['default'] | Should -BeOfType ([bool])
            $inputs['deploymentValidation']['default'] | Should -BeTrue
        }
        It 'does not default the custom location' -Tag 'avm.bicep.workflow-custom-location' {
            $inputs['customLocation'] | Should -BeOfType ([System.Collections.IDictionary])
            $inputs['customLocation'].Contains('default') | Should -BeFalse
        }
        It 'limits push options to branches and paths' -Tag 'avm.bicep.workflow-push-options' {
            @($push.psbase.Keys | Where-Object { $_ -cnotin @('branches', 'paths') }) | Should -HaveCount 0
        }
        It 'runs automatically only on main' -Tag 'avm.bicep.workflow-push-branches' {
            $branches = @(if ($push.Contains('branches')) { $push['branches'] })
            @($branches) | Should -HaveCount 1
            $branches[0] | Should -BeOfType ([string])
            $branches[0] | Should -BeExactly 'main'
        }
        It 'includes every canonical push filter' -Tag 'avm.bicep.workflow-push-paths-missing' {
            @($expectedPaths | Where-Object { $paths -cnotcontains $_ }) | Should -HaveCount 0
        }
        It 'has exactly four canonical push filters' -Tag 'avm.bicep.workflow-push-paths-excess' {
            @($paths) | Should -HaveCount 4
            @($paths | Where-Object { $_ -isnot [string] -or $_ -cnotin $expectedPaths }) | Should -HaveCount 0
            @($paths | Select-Object -Unique) | Should -HaveCount 4
        }
        It 'excludes metadata after all positive filters' -Tag 'avm.bicep.workflow-push-metadata-last' {
            @($paths) | Should -Not -BeNullOrEmpty
            $paths[-1] | Should -BeExactly '!avm/**/metadata.json'
        }
        It 'orders push filters canonically' -Tag 'avm.bicep.workflow-push-paths-order' {
            @($paths) | Should -HaveCount 4
            for ($index = 0; $index -lt 4; $index++) {
                $paths[$index] | Should -BeExactly $expectedPaths[$index]
            }
        }
        It 'guards initialization against cancellation and automatic fork runs' -Tag 'avm.bicep.workflow-condition' {
            $workflow['jobs'] | Should -BeOfType ([System.Collections.IDictionary])
            $workflow['jobs']['job_initialize_pipeline'] | Should -BeOfType ([System.Collections.IDictionary])
            $condition = $workflow['jobs']['job_initialize_pipeline']['if']
            $condition | Should -BeOfType ([string])
            $expression = $condition.Trim()
            if ($expression.StartsWith('${{', [System.StringComparison]::Ordinal) -and
                $expression.EndsWith('}}', [System.StringComparison]::Ordinal)) {
                $expression = $expression.Substring(3, $expression.Length - 5).Trim()
            }
            $expression | Should -MatchExactly "^\s*!cancelled\(\)\s*&&\s*!\(\s*github\.repository\s*!=\s*'Azure/bicep-registry-modules'\s*&&\s*github\.event_name\s*!=\s*'workflow_dispatch'\s*\)\s*$"
        }
    }
}
