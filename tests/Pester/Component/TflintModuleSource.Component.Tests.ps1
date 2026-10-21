#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Component: TFLint module source configuration' -Tag 'Component' {
    BeforeAll {
        $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
        Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $script:savedHome = [System.Environment]::GetEnvironmentVariable('AVM_HOME')
        $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        $script:configDir = Join-Path $moduleRoot 'Resources' 'tflint'
    }

    AfterAll {
        $homeValue = if ($null -eq $script:savedHome) { [NullString]::Value } else { $script:savedHome }
        [System.Environment]::SetEnvironmentVariable('AVM_HOME', $homeValue)
        Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'preserves submodule context through shared and per-scope overrides without changing inputs' {
        $root = Join-Path $TestDrive 'repository'
        foreach ($path in @(
                (Join-Path $root 'modules' 'part'),
                (Join-Path $root 'modules' 'part-component'),
                (Join-Path $root 'examples' 'default')
            )) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }

        $sharedOverride = Join-Path $root 'avm.tflint_module.override.hcl'
        $scopeOverride = Join-Path $root 'modules' 'part' 'avm.tflint.override.hcl'
        [System.IO.File]::WriteAllText($sharedOverride, @'
rule "avm_terraform_module_source_required" {
  severity = "warning"
}
'@)
        [System.IO.File]::WriteAllText($scopeOverride, @'
rule "avm_terraform_module_source_required" {
  severity = "error"
}
'@)

        $inputPaths = @(
            Get-ChildItem -LiteralPath $script:configDir -File -Filter '*.hcl' |
                Select-Object -ExpandProperty FullName
            $sharedOverride
            $scopeOverride
        )
        $before = Get-FileHash -LiteralPath $inputPaths
        $configs = InModuleScope 'Avm.Authoring' -Parameters @{
            Root = $root
            ConfigDir = $script:configDir
        } {
            param($Root, $ConfigDir)
            $script:configCopyCommand = Get-Command -Name 'Microsoft.PowerShell.Management\Copy-Item' -CommandType Cmdlet
            Mock Copy-Item { & $script:configCopyCommand @PesterBoundParameters }
            $scopes = @(Get-AvmTflintScope -Root $Root -ConfigDir $ConfigDir)
            $set = New-AvmTflintConfigSet -Root $Root -BaseConfigDir $ConfigDir -Scopes $scopes
            try {
                Should -Invoke Copy-Item -Exactly 2 -ParameterFilter {
                    $ProgressAction -eq 'SilentlyContinue'
                }
                Should -Invoke Copy-Item -Exactly 0 -ParameterFilter {
                    $ProgressAction -ne 'SilentlyContinue'
                }
                foreach ($scope in $scopes) {
                    $name = if ($set.ScopeConfigNames.ContainsKey($scope.RelPath)) {
                        $set.ScopeConfigNames[$scope.RelPath]
                    }
                    else {
                        [System.IO.Path]::GetFileName($scope.Config)
                    }
                    $rules = @(Get-AvmTflintOverrideBlock -Path (Join-Path $set.ConfigDir $name) |
                            Where-Object { $_.Type -ceq 'rule' -and $_.Label -ceq 'avm_terraform_module_source_required' })
                    [pscustomobject]@{
                        Scope = $scope.RelPath
                        Rules = $rules
                    }
                }
            }
            finally {
                Remove-Item -LiteralPath $set.StageDir -Recurse -Force
            }
        }

        @($configs).Count | Should -Be 4
        @($configs | Where-Object Scope -eq '.')[0].Rules | Should -BeNullOrEmpty
        foreach ($scope in @('modules/part', 'modules/part-component')) {
            $rule = @($configs | Where-Object Scope -eq $scope)[0].Rules
            $rule.Count | Should -Be 1
            @($rule.Attributes | Where-Object Name -eq 'module_scope').Value | Should -Be '"submodule"'
            @($rule.Attributes | Where-Object Name -eq 'enabled').Value | Should -Be 'true'
            $expectedSeverity = if ($scope -eq 'modules/part') { '"error"' } else { '"warning"' }
            @($rule.Attributes | Where-Object Name -eq 'severity').Value | Should -Be $expectedSeverity
        }
        $exampleRule = @($configs | Where-Object Scope -eq 'examples/default')[0].Rules
        @($exampleRule.Attributes | Where-Object Name -eq 'enabled').Value | Should -Be 'false'
        @($exampleRule.Attributes | Where-Object Name -eq 'module_scope') | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $inputPaths).Hash | Should -Be $before.Hash
    }
}
