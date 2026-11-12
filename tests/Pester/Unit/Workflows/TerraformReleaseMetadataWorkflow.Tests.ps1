#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'terraform-release-metadata reusable workflow' {
    BeforeAll {
        $script:workflowPath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'terraform-release-metadata.yml'
        $script:workflow = Get-Content -LiteralPath $script:workflowPath -Raw

        $jobMatch = [regex]::Match($script:workflow, '(?ms)^  validate:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        if (-not $jobMatch.Success) { throw 'Could not isolate the validate job block.' }
        $script:validateJob = $jobMatch.Value
        $bootstrapMatch = [regex]::Match($script:workflow, '(?ms)^  bootstrap:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        if (-not $bootstrapMatch.Success) { throw 'Could not isolate the bootstrap job block.' }
        $script:bootstrapJob = $bootstrapMatch.Value
    }

    It 'is a reusable workflow with the standard authoring inputs' {
        $script:workflow | Should -Match "(?m)^name: 'Reusable: Terraform release metadata'\r?$"
        $script:workflow | Should -Match '(?m)^  workflow_call:\r?$'
        $script:workflow | Should -Match '(?m)^      authoringSource:\r?$'
        $script:workflow | Should -Match '(?m)^      authoringRef:\r?$'
        $script:workflow | Should -Match '(?m)^      pullRequestNumber:\r?\n(?:        .*\r?\n)*?        type: number\r?$'
    }

    It 'grants no workflow permissions and only read permissions to jobs' {
        $script:workflow | Should -Match '(?m)^permissions: \{\}\r?$'
        $script:workflow | Should -Not -Match ':\s*write\b'
        $script:bootstrapJob | Should -Match '(?m)^    permissions:\r?\n      contents: read\r?$'
        $script:validateJob | Should -Match '(?m)^    permissions:\r?\n      contents: read\r?\n      issues: read\r?\n      pull-requests: read\r?$'
    }

    It 'never checks out pull request code or reads secrets' {
        $script:workflow | Should -Not -Match 'actions/checkout'
        $script:workflow | Should -Not -Match '\$\{\{\s*secrets\.|secrets: inherit'
        $script:validateJob | Should -Match 'GH_TOKEN: \$\{\{ github\.token \}\}'
    }

    It 'bootstraps Avm.Authoring through the shared authoring bootstrap' {
        $script:bootstrapJob | Should -Match 'uses: \./\.github/workflows/authoring-bootstrap\.yml'
        $script:bootstrapJob | Should -Match 'authoringSource: \$\{\{ inputs\.authoringSource \}\}'
        $script:bootstrapJob | Should -Match 'authoringRef: \$\{\{ inputs\.authoringRef \}\}'
        $script:validateJob | Should -Match 'uses: actions/download-artifact@[0-9a-f]{40} # v'
        $script:validateJob | Should -Match 'name: \$\{\{ needs\.bootstrap\.outputs\.artifact \}\}'
    }

    It 'reports as release-metadata / Validate when called from a release-metadata job' {
        $script:validateJob | Should -Match '(?m)^    name: Validate\r?$'
        $script:workflow | Should -Match 'jobs:\r?\n(?:#.*\r?\n)*.*release-metadata:\r?\n.*uses: Azure/azure-verified-modules-tools/\.github/workflows/terraform-release-metadata\.yml@'
    }

    It 'fails instead of skipping when the authoring runtime is not prepared' {
        $script:validateJob | Should -Match '(?m)^    if: \$\{\{ !cancelled\(\) \}\}\r?$'
        $script:validateJob | Should -Match "if: needs\.bootstrap\.result != 'success'"
        $script:validateJob | Should -Match 'throw \[InvalidOperationException\]::new\("The authoring runtime was not prepared'
        $script:validateJob | Should -Not -Match 'continue-on-error:'
    }

    It 'requires the release-metadata capability before running the check' {
        $script:validateJob | Should -Match '\$capabilities\.TerraformReleaseMetadata -isnot \[int\] -or \$capabilities\.TerraformReleaseMetadata -ne 1'
        $script:validateJob | Should -Match 'Invoke-AvmReleaseMetadataCheck @parameters'
        $script:validateJob | Should -Match 'SkipModuleVersionCheck = \$true'
        $script:validateJob | Should -Match "if \(\`$result\.Status -cne 'pass'\) \{\r?\n\s+exit 1"
    }

    It 'validates the pull request number input before using it' {
        $script:validateJob | Should -Match 'PULL_REQUEST_NUMBER: \$\{\{ inputs\.pullRequestNumber \}\}'
        $script:validateJob | Should -Match "-cnotmatch '\^\(0\|\[1-9\]\\d\{0,8\}\)\$'"
        $script:validateJob | Should -Not -Match 'run:.*\$\{\{ inputs\.'
    }

    It 'sets a writable AVM home for the terraform formatter' {
        $script:validateJob | Should -Match '"AVM_HOME=\$avmHome" \| Out-File -FilePath \$env:GITHUB_ENV'
    }
}
