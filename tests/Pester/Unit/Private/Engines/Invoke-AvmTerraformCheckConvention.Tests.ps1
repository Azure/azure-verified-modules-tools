#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force

    function script:NewRoot {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root | Out-Null
        return $root
    }

    function script:WriteRuleFile {
        param([string] $Path, [string] $Content)
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($Path, $Content, $utf8)
    }

    function script:NewTerraformContext {
        param([string] $Root)
        return [pscustomobject]@{ Ecosystem = 'terraform'; Root = $Root }
    }

    function script:NewClassifiedRoot {
        param([string] $ModuleType)

        $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
        $root = Join-Path $TestDrive "terraform-azurerm-avm-$kind-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $root | Out-Null
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $root 'terraform.tf'), '# stub', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $root '_header.md'), '# header', $utf8)
        New-Item -ItemType Directory -Path (Join-Path $root 'tests') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'tests/.gitkeep'), '', $utf8)
        if ($ModuleType -ne 'resource') {
            $metadata = [ordered]@{
                '$schema'          = 'https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json'
                moduleDisplayName  = 'Example fixture'
                moduleDescription  = 'Tests required examples.'
                canonicalType      = if ($ModuleType -eq 'pattern') { 'aiml-ai-gateway' } else { 'regions' }
                owners             = @('module-owner')
            }
            if ($ModuleType -eq 'pattern') {
                $metadata.telemetryIdPrefix = '46d3xtrf.ptn.a1b2c3d'
            }
            [System.IO.File]::WriteAllText((Join-Path $root 'metadata.json'),
                (ConvertTo-Json -InputObject $metadata -Depth 5) + "`n", $utf8)
        }
        return $root
    }

    function script:AddRunnableExample {
        param([string] $Root, [string] $Name, [switch] $Ignored, [switch] $Empty)

        $path = Join-Path $Root 'examples' $Name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        if (-not $Empty) {
            [System.IO.File]::WriteAllText(
                (Join-Path $path 'main.tf'), "terraform {}`n", [System.Text.UTF8Encoding]::new($false))
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $path '_header.md'), "# $Name`n", [System.Text.UTF8Encoding]::new($false))
        if ($Ignored) {
            [System.IO.File]::WriteAllText(
                (Join-Path $path '.e2eignore'), "Temporarily excluded.`n", [System.Text.UTF8Encoding]::new($false))
        }
    }

    # Pre-stages the minimum on-disk shape (files + dirs) that
    # satisfies every error-severity built-in rule shipped under
    # src/Avm.Authoring/Resources/Rules/. After calling this, no built-in
    # rule should fire. Tests can then layer their own per-repo rules on top.
    function script:NewBaselineRoot {
        $root = script:NewRoot
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $root 'terraform.tf'), '# stub', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $root '_header.md'), '# header', $utf8)
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'examples/default/_header.md'), '# header', $utf8)
        New-Item -ItemType Directory -Path (Join-Path $root 'tests/unit') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'tests/unit/main.tftest.hcl'), '# test', $utf8)
        return $root
    }
}

Describe 'Invoke-AvmTerraformCheckConvention engine' {
    It 'rejects a non-terraform context with ArgumentException' {
        $ctx = [pscustomobject]@{ Ecosystem = 'bicep'; Root = $TestDrive }
        { InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C } } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'returns the standard envelope with Tool=avm-rules/1 and ToolSource=builtin' {
        $root = script:NewRoot
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $result.Engine | Should -Be 'terraform'
        $result.Tool | Should -Be 'avm-rules/1'
        $result.ToolPath | Should -BeNullOrEmpty
        $result.ToolSource | Should -Be 'builtin'
    }

    It 'returns status=pass when only warning-severity issues fire' {
        # Baseline root satisfies every error-severity built-in rule
        # (terraform.tf, _header.md, examples/, tests/), so no
        # built-in rule fires. A per-repo warning-severity rule for a missing
        # file is layered on to prove a firing warning does not flip Status.
        $root = script:NewBaselineRoot
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'warn.psd1') @'
@{
    Id          = 'avm.warn.optional-file'
    Kind        = 'FileMustExist'
    Description = 'optional file is recommended'
    Severity    = 'warning'
    AppliesTo   = 'root'
    Parameters  = @{ Path = 'OPTIONAL.md' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $result.Status | Should -Be 'pass'
        $warnIssues = @($result.Issues | Where-Object Code -eq 'avm.warn.optional-file')
        $warnIssues.Count | Should -BeGreaterOrEqual 1
        $warnIssues[0].Severity | Should -Be 'warning'
    }

    It 'returns status=fail when at least one issue is severity=error' {
        $root = script:NewRoot
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'errrule.psd1') @'
@{
    Id          = 'avm.err.requires-terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'terraform.tf must exist'
    Severity    = 'error'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $result.Status | Should -Be 'fail'
        ($result.Issues | Where-Object Code -eq 'avm.err.requires-terraform-tf') | Should -Not -BeNullOrEmpty
    }

    It 'rejects nested Terraform scope roots without rejecting nested asset directories' {
        $root = script:NewBaselineRoot
        foreach ($path in @(
                'modules/network/private/main.tf',
                'examples/default/secondary/main.tf',
                'modules/network/scripts/generate.ps1',
                'examples/default/assets/template.json'
            )) {
            $file = Join-Path $root $path
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            [System.IO.File]::WriteAllText($file, '# fixture', [System.Text.UTF8Encoding]::new($false))
        }

        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Invoke-AvmTerraformCheckConvention -Context $C
        }

        $nestedIssues = @($result.Issues | Where-Object Code -eq 'avm.tf.terraform-scopes-must-be-direct-children')
        $nestedIssues.Count | Should -Be 2
        @($nestedIssues.File | Sort-Object) | Should -Be @(
            'examples/default/secondary/main.tf'
            'modules/network/private/main.tf'
        )
        $result.Status | Should -Be 'fail'
    }

    It 'ignores .terraform build artifacts when discovering nested scopes' {
        # Regression: https://github.com/Azure/azure-verified-modules-tools/issues/85
        # 'terraform init' populates .terraform/modules/ with copies of external
        # modules. They are gitignored build output, so a stale one must not be
        # reported as a nested scope the author has to move.
        $root = script:NewBaselineRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'modules/slot') -Force | Out-Null
        foreach ($stub in @('modules/slot/terraform.tf', 'modules/slot/_header.md')) {
            [System.IO.File]::WriteAllText(
                (Join-Path $root $stub), '# stub', [System.Text.UTF8Encoding]::new($false))
        }
        foreach ($path in @(
                'modules/slot/.terraform/modules/avm_interfaces/main.tf',
                'modules/slot/.terraform/modules/avm_interfaces/nested/outputs.tf',
                'examples/default/.terraform/modules/foo/main.tf'
            )) {
            $file = Join-Path $root $path
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            [System.IO.File]::WriteAllText($file, '# downloaded', [System.Text.UTF8Encoding]::new($false))
        }

        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Invoke-AvmTerraformCheckConvention -Context $C
        }

        @($result.Issues | Where-Object Code -eq 'avm.tf.terraform-scopes-must-be-direct-children') |
            Should -BeNullOrEmpty
        $result.Status | Should -Be 'pass'
    }

    It 'expands AppliesTo=examples into each examples/{name} subdirectory' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/second')  -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'each-example.psd1') @'
@{
    Id          = 'avm.examples.terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'each example needs terraform.tf'
    AppliesTo   = 'examples'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $exampleIssues = @($result.Issues | Where-Object Code -eq 'avm.examples.terraform-tf')
        $exampleIssues.Count | Should -Be 2
        ($exampleIssues.File | Sort-Object) | Should -Be @('examples/default/terraform.tf', 'examples/second/terraform.tf')
    }

    It 'expands AppliesTo=modules into each modules/{name} subdirectory' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'modules/private-endpoint') -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'each-module.psd1') @'
@{
    Id          = 'avm.modules.terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'each module needs terraform.tf'
    AppliesTo   = 'modules'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $modIssues = @($result.Issues | Where-Object Code -eq 'avm.modules.terraform-tf')
        $modIssues.Count | Should -Be 1
        $modIssues[0].File | Should -Be 'modules/private-endpoint/terraform.tf'
    }

    It 'excludes .terraform from the expanded examples and modules targets' {
        # Regression: https://github.com/Azure/azure-verified-modules-tools/issues/85
        # 'terraform init' run directly in examples/ or modules/ leaves a
        # .terraform directory there. It is not a scope, so no rule targets it.
        $root = script:NewRoot
        foreach ($dir in @(
                'examples/default',
                'examples/.terraform/modules',
                'modules/private-endpoint',
                'modules/.terraform/modules'
            )) {
            New-Item -ItemType Directory -Path (Join-Path $root $dir) -Force | Out-Null
        }

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'each-scope.psd1') @'
@{
    Id          = 'avm.scopes.terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'each scope needs terraform.tf'
    AppliesTo   = @('examples', 'modules')
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $scopeIssues = @($result.Issues | Where-Object Code -eq 'avm.scopes.terraform-tf')
        ($scopeIssues.File | Sort-Object) | Should -Be @(
            'examples/default/terraform.tf'
            'modules/private-endpoint/terraform.tf'
        )
    }

    It 'AppliesTo=all walks root + examples/* + modules/*' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'modules/sub')      -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'all.psd1') @'
@{
    Id          = 'avm.all.terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'terraform.tf everywhere'
    AppliesTo   = 'all'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $issuesForRule = @($result.Issues | Where-Object Code -eq 'avm.all.terraform-tf')
        $files = ($issuesForRule.File | Sort-Object)
        $files | Should -Contain 'terraform.tf'
        $files | Should -Contain 'examples/default/terraform.tf'
        $files | Should -Contain 'modules/sub/terraform.tf'
        $issuesForRule.Count | Should -Be 3
    }

    It 'expands an AppliesTo array into exactly the named scopes' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'modules/sub')      -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'root-and-modules.psd1') @'
@{
    Id          = 'avm.scoped.terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'terraform.tf at root and in nested modules'
    AppliesTo   = @('root', 'modules')
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $files = @($result.Issues | Where-Object Code -eq 'avm.scoped.terraform-tf').File | Sort-Object
        $files | Should -Be @('modules/sub/terraform.tf', 'terraform.tf')
        $files | Should -Not -Contain 'examples/default/terraform.tf'
    }

    It 'evaluates an AppliesTo array in canonical root/examples/modules order' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'modules/sub')      -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        # Authored out of order and with a duplicate; expansion must normalise.
        script:WriteRuleFile (Join-Path $repoDir 'unordered.psd1') @'
@{
    Id          = 'avm.scoped.ordered'
    Kind        = 'FileMustExist'
    Description = 'scopes are normalised regardless of authored order'
    AppliesTo   = @('modules', 'root', 'modules')
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $files = @(@($result.Issues | Where-Object Code -eq 'avm.scoped.ordered').File)
        $files | Should -Be @('terraform.tf', 'modules/sub/terraform.tf')
    }

    Context 'F08 - the built-in terraform.tf rule ignores examples' {
        It 'does not fire for examples that have no terraform.tf' {
            $root = script:NewBaselineRoot
            New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'examples/second')  -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'examples/default/_header.md'), '# h', [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $root 'examples/second/_header.md'), '# h', [System.Text.UTF8Encoding]::new($false))

            $ctx = script:NewTerraformContext $root
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }
            @($result.Issues | Where-Object Code -eq 'avm.tf.terraform-tf-must-exist') | Should -BeNullOrEmpty
            $result.Status | Should -Be 'pass'
        }

        It 'still fires for a nested module that has no terraform.tf' {
            $root = script:NewBaselineRoot
            New-Item -ItemType Directory -Path (Join-Path $root 'modules/sub') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'modules/sub/_header.md'), '# h', [System.Text.UTF8Encoding]::new($false))

            $ctx = script:NewTerraformContext $root
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }
            $issues = @($result.Issues | Where-Object Code -eq 'avm.tf.terraform-tf-must-exist')
            $issues.Count | Should -Be 1
            $issues[0].File | Should -Be 'modules/sub/terraform.tf'
            $result.Status | Should -Be 'fail'
        }

        It 'still fires when the repository root has no terraform.tf' {
            $root = script:NewBaselineRoot
            Remove-Item -LiteralPath (Join-Path $root 'terraform.tf') -Force

            $ctx = script:NewTerraformContext $root
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }
            $issues = @($result.Issues | Where-Object Code -eq 'avm.tf.terraform-tf-must-exist')
            $issues.Count | Should -Be 1
            $issues[0].File | Should -Be 'terraform.tf'
        }

        It 'passes on a mixed repository where only examples lack terraform.tf' {
            $root = script:NewBaselineRoot
            foreach ($rel in @('examples/default', 'examples/second', 'modules/sub')) {
                New-Item -ItemType Directory -Path (Join-Path $root $rel) -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $root "$rel/_header.md"), '# h', [System.Text.UTF8Encoding]::new($false))
            }
            [System.IO.File]::WriteAllText((Join-Path $root 'modules/sub/terraform.tf'), '# stub', [System.Text.UTF8Encoding]::new($false))

            $ctx = script:NewTerraformContext $root
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }
            @($result.Issues | Where-Object Code -eq 'avm.tf.terraform-tf-must-exist') | Should -BeNullOrEmpty
            $result.Status | Should -Be 'pass'
        }
    }

    It 'emits no Issues when an AppliesTo=examples rule has no example subdirectories' {
        $root = script:NewRoot   # no examples/ at all
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'each-example.psd1') @'
@{
    Id          = 'avm.examples.requires'
    Kind        = 'FileMustExist'
    Description = 'each example needs terraform.tf'
    AppliesTo   = 'examples'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        @($result.Issues | Where-Object Code -eq 'avm.examples.requires') | Should -BeNullOrEmpty
    }

    It 'plumbs -Fix through to primitives that declare a fix path' {
        $root = script:NewRoot
        Set-Content -LiteralPath (Join-Path $root 'output.tf') -Value '# stub' -NoNewline

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'rename.psd1') @'
@{
    Id          = 'avm.fix.rename-output-tf'
    Kind        = 'FileMustNotExist'
    Description = 'output.tf must be renamed'
    Parameters  = @{ Path = 'output.tf'; FixRenameTo = 'outputs.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C -Fix | Out-Null
        }
        Test-Path -LiteralPath (Join-Path $root 'output.tf')  | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'outputs.tf') | Should -BeTrue
    }

    It 'fixes only rules with an associated fix when -FixableOnly is set' {
        $root = script:NewRoot
        Set-Content -LiteralPath (Join-Path $root 'output.tf') -Value '# stub' -NoNewline
        $ctx = script:NewTerraformContext $root

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C -Fix -FixableOnly
        }

        $result.Status | Should -Be 'pass'
        @($result.Issues).Count | Should -Be 0
        Join-Path $root 'output.tf' | Should -Not -Exist
        Join-Path $root 'outputs.tf' | Should -Exist
        Join-Path $root '_header.md' | Should -Exist
        Join-Path $root 'tests/.gitkeep' | Should -Exist
        Join-Path $root 'terraform.tf' | Should -Not -Exist
        Join-Path $root 'examples' | Should -Not -Exist

        $strictResult = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $strictResult.Status | Should -Be 'fail'
        $strictResult.Issues.Code | Should -Contain 'avm.tf.terraform-tf-must-exist'
        $strictResult.Issues.Code | Should -Contain 'avm.tf.examples-dir-must-exist'
    }

    It 'emits forward-slash separators in Issue.File even on Windows-style joined paths' {
        $root = script:NewRoot
        New-Item -ItemType Directory -Path (Join-Path $root 'examples/default') -Force | Out-Null

        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        script:WriteRuleFile (Join-Path $repoDir 'each.psd1') @'
@{
    Id          = 'avm.examples.terraform-tf'
    Kind        = 'FileMustExist'
    Description = 'd'
    AppliesTo   = 'examples'
    Parameters  = @{ Path = 'terraform.tf' }
}
'@
        $ctx = script:NewTerraformContext $root
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C) Invoke-AvmTerraformCheckConvention -Context $C
        }
        $issue = $result.Issues | Where-Object Code -eq 'avm.examples.terraform-tf' | Select-Object -First 1
        $issue.File | Should -Be 'examples/default/terraform.tf'
        $issue.File | Should -Not -Match '\\'
    }

    Context 'TFNFR42 canonical examples' {
        It 'requires defaults for <ModuleType> without requiring WAF for non-resource modules' -ForEach @(
            @{ ModuleType = 'resource'; WafIssues = 0 }
            @{ ModuleType = 'pattern'; WafIssues = 0 }
            @{ ModuleType = 'utility'; WafIssues = 0 }
        ) {
            $root = script:NewClassifiedRoot $ModuleType
            script:AddRunnableExample -Root $root -Name 'defaults'
            if ($ModuleType -eq 'resource') {
                script:AddRunnableExample -Root $root -Name 'waf-aligned'
            }

            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = (script:NewTerraformContext $root) } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }

            $result.Status | Should -Be 'pass'
            @($result.Issues | Where-Object Code -like 'avm.tf.tfnfr42-required-examples*') |
                Should -HaveCount $WafIssues
        }

        It 'warns for resource-only missing WAF coverage without failing status' {
            $root = script:NewClassifiedRoot 'resource'
            script:AddRunnableExample -Root $root -Name 'defaults'

            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = (script:NewTerraformContext $root) } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }
            $issues = @($result.Issues | Where-Object Code -eq 'avm.tf.tfnfr42-required-examples.missing-waf-aligned')

            $result.Status | Should -Be 'pass'
            $issues | Should -HaveCount 1
            $issues[0].Severity | Should -BeExactly 'warning'
        }

        It 'reports singular-only defaults as a runnable migration warning' {
            $root = script:NewClassifiedRoot 'pattern'
            script:AddRunnableExample -Root $root -Name 'default'

            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = (script:NewTerraformContext $root) } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }
            $issue = @($result.Issues | Where-Object Code -eq 'avm.tf.tfnfr42-required-examples.missing-defaults')[0]

            $issue.Severity | Should -BeExactly 'warning'
            $issue.Message | Should -Match 'legacy spelling remains runnable'
        }

        It 'warns when both default spellings are present without failing status' {
            $root = script:NewClassifiedRoot 'utility'
            script:AddRunnableExample -Root $root -Name 'default'
            script:AddRunnableExample -Root $root -Name 'defaults'

            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = (script:NewTerraformContext $root) } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }

            $result.Status | Should -Be 'pass'
            @($result.Issues | Where-Object Code -eq 'avm.tf.tfnfr42-required-examples.legacy-default') |
                Should -HaveCount 1
        }

        It 'does not accept case variants, empty folders, or ignored folders as canonical examples: <Case>' -ForEach @(
            @{ Case = 'case variant'; Name = 'Defaults' }
            @{ Case = 'empty folder'; Name = 'defaults'; Empty = $true }
            @{ Case = 'ignored folder'; Name = 'defaults'; Ignored = $true }
        ) {
            param($Case, $Name, $Empty = $false, $Ignored = $false)
            $root = script:NewClassifiedRoot 'utility'
            script:AddRunnableExample -Root $root -Name $Name -Empty:$Empty -Ignored:$Ignored

            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = (script:NewTerraformContext $root) } {
                param($C) Invoke-AvmTerraformCheckConvention -Context $C
            }

            @($result.Issues | Where-Object Code -eq 'avm.tf.tfnfr42-required-examples.missing-defaults') |
                Should -HaveCount 1
            $result.Status | Should -Be 'pass'
        }

        It 'fails closed when non-resource metadata cannot validate the classification' {
            $root = script:NewClassifiedRoot 'pattern'
            Set-Content -LiteralPath (Join-Path $root 'metadata.json') -Value '{"canonicalType":42}' -Encoding utf8NoBOM
            script:AddRunnableExample -Root $root -Name 'defaults'

            {
                InModuleScope 'Avm.Authoring' -Parameters @{ C = (script:NewTerraformContext $root) } {
                    param($C) Invoke-AvmTerraformCheckConvention -Context $C
                }
            } | Should -Throw
        }
    }
}
