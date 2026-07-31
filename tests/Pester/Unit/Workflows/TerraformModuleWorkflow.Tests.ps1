#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'terraform-module reusable workflow' {
    BeforeAll {
        $script:workflowPath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'terraform-module.yml'
        $script:workflow = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'passes the non-secret subscription ID as a job output without masking it' {
        $script:workflow | Should -Match '"subscriptionId=\$\(\$chosen\.id\)"'
        $script:workflow | Should -Not -Match '::add-mask::\$\(\$chosen\.id\)'
    }
}
