#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).ProviderPath
    $script:fixtureRoot = Join-Path $script:repoRoot 'tests' 'fixtures' 'bicep-convention'
    . (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep PSRule policy checks' -Tag 'Component' {
    BeforeEach {
        $script:workingRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:fixtureRoot -Destination $script:workingRoot -Recurse
        $script:modulePath = Join-Path $script:workingRoot 'avm' 'res' 'mock' 'widget'
        $script:previousNamePrefix = $env:TOKEN_NAMEPREFIX
        $script:previousLocalNamePrefix = $env:localToken_namePrefix
        $env:TOKEN_NAMEPREFIX = 'avmpolicy'
        Remove-Item Env:localToken_namePrefix -ErrorAction SilentlyContinue

        InModuleScope 'Avm.Authoring' {
            $script:stageInputs = [System.Collections.Generic.List[object]]::new()
            Mock Import-AvmBicepPolicyModule {
                [pscustomobject]@{ Name = 'PSRule (fixture)'; Path = 'fixture' }
            }
            Mock Get-AvmBicepPolicyConfiguration {
                $folder = Join-Path $RepositoryRoot 'utilities' 'pipelines' `
                    'staticValidation' 'psrule'
                [pscustomobject]@{
                    OptionPath = Join-Path $folder 'ps-rule.yaml'
                    RulePath   = Join-Path $folder '.ps-rule'
                    Option     = $null
                }
            }
            Mock Get-AvmBicepPolicyBaseline {
                $names = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::Ordinal)
                $null = $names.Add('Azure.Sample.Rule')
                [pscustomobject]@{ Name = $Name; RuleNames = $names }
            }
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = 'fixture'; Path = 'mock-bicep'; Source = 'fixture'
                }
            }
            Mock Invoke-AvmBicepPolicyBaseline {
                $test = [System.IO.Path]::GetFullPath((Join-Path $StageRoot $InputPath))
                $script:stageInputs.Add([pscustomobject]@{
                        Root        = $StageRoot
                        Test        = [System.IO.File]::ReadAllText($test)
                        HasMain     = [System.IO.File]::Exists(
                            (Join-Path $StageRoot 'avm/res/mock/widget/main.bicep'))
                        HasMetadata = [System.IO.File]::Exists(
                            (Join-Path $StageRoot 'avm/res/mock/widget/metadata.json'))
                    })
                [pscustomobject]@{
                    Source     = @([pscustomobject]@{ File = $test })
                    RuleName   = 'Azure.Sample.Rule'
                    TargetType = 'Microsoft.Storage/storageAccounts'
                    Outcome    = 'Pass'
                    Error      = $null
                }
            }
        }
    }

    AfterEach {
        if ($null -eq $script:previousNamePrefix) {
            Remove-Item Env:TOKEN_NAMEPREFIX -ErrorAction SilentlyContinue
        }
        else {
            $env:TOKEN_NAMEPREFIX = $script:previousNamePrefix
        }
        if ($null -eq $script:previousLocalNamePrefix) {
            Remove-Item Env:localToken_namePrefix -ErrorAction SilentlyContinue
        }
        else {
            $env:localToken_namePrefix = $script:previousLocalNamePrefix
        }
        Remove-Item Env:localToken_moduleSuffix -ErrorAction SilentlyContinue
    }

    It 'runs all four baselines against each selected test and stages its references without editing sources' {
        $before = [System.IO.File]::ReadAllText(
            (Join-Path $script:modulePath 'tests/e2e/defaults/main.test.bicep'))
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck

        $result.Status | Should -Be 'pass'
        $result.ToolSource | Should -Be 'powershell-module'
        $result.TestsSelected | Should -Be 2
        $result.BaselinesExecuted | Should -Be 8
        $result.Evaluations.Baseline | Select-Object -Unique |
            Should -Be @('Azure.Pillar.Reliability', 'CB.AVM.WAF.Security',
                'Azure.Default', 'Azure.Pillar.Security')
        $result.Issues.Count | Should -Be 0
        $before | Should -Match '#_namePrefix_#'
        [System.IO.File]::ReadAllText(
            (Join-Path $script:modulePath 'tests/e2e/defaults/main.test.bicep')) |
            Should -BeExactly $before

        InModuleScope 'Avm.Authoring' {
            $script:stageInputs.Count | Should -Be 8
            foreach ($input in $script:stageInputs) {
                $input.Test | Should -Match 'avmpolicy'
                $input.Test | Should -Not -Match '#_namePrefix_#'
                $input.HasMain | Should -BeTrue
                $input.HasMetadata | Should -BeTrue
                [System.IO.Directory]::Exists($input.Root) | Should -BeFalse
            }
            Should -Invoke Invoke-AvmBicepPolicyBaseline -Exactly 8
        }
    }

    It 'discovers selected tests in direct and modules-directory children' {
        foreach ($relative in @('child', 'modules/nested')) {
            $target = Join-Path $script:modulePath $relative
            $testFolder = Join-Path $target 'tests/e2e/defaults'
            $null = New-Item -ItemType Directory -Path $testFolder -Force
            Copy-Item -LiteralPath (Join-Path $script:modulePath 'tests/e2e/defaults/main.test.bicep') `
                -Destination (Join-Path $testFolder 'main.test.bicep')
            if ($relative -eq 'modules/nested') {
                Copy-Item -LiteralPath (Join-Path $script:modulePath 'main.bicep') `
                    -Destination (Join-Path $target 'main.bicep')
                Copy-Item -LiteralPath (Join-Path $script:modulePath 'metadata.json') `
                    -Destination (Join-Path $target 'metadata.json')
            }
        }

        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $result.TestsSelected | Should -Be 4
        $result.BaselinesExecuted | Should -Be 16
        $result.Evaluations.File | Should -Contain 'child/tests/e2e/defaults/main.test.bicep'
        $result.Evaluations.File | Should -Contain 'modules/nested/tests/e2e/defaults/main.test.bicep'
    }

    It 'replaces local tokens in a referenced module and follows transitive local modules' {
        $sourcePath = Join-Path $script:modulePath 'main.bicep'
        $source = [System.IO.File]::ReadAllText($sourcePath)
        $source += "`nvar localMarker = '#_moduleSuffix_#'`n"
        $source += "module childModule './child/main.bicep' = {`n  name: 'sample'`n  params: { name: 'sample' }`n}`n"
        [System.IO.File]::WriteAllText($sourcePath, $source)
        $env:localToken_moduleSuffix = 'safe-suffix'
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPolicyBaseline {
                $source = Join-Path $StageRoot 'avm/res/mock/widget/main.bicep'
                $sourceText = [System.IO.File]::ReadAllText($source)
                $sourceText | Should -Match 'safe-suffix'
                $sourceText | Should -Not -Match '#_moduleSuffix_#'
                [System.IO.File]::Exists(
                    (Join-Path $StageRoot 'avm/res/mock/widget/child/main.bicep')) | Should -BeTrue
                [pscustomobject]@{
                    Source = @([pscustomobject]@{
                            File = [System.IO.Path]::GetFullPath((Join-Path $StageRoot $InputPath))
                        })
                    RuleName = 'Azure.Sample.Rule'; TargetType = 'Microsoft.Storage/storageAccounts'
                    Outcome = 'Pass'; Error = $null
                }
            }
        }

        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        [System.IO.File]::ReadAllText($sourcePath) | Should -BeExactly $source
    }

    It 'tokenizes a loadTextContent reference even when it is a PowerShell file' {
        $sourcePath = Join-Path $script:modulePath 'main.bicep'
        [System.IO.File]::AppendAllText(
            $sourcePath, "`nvar encodedHelper = loadFileAsBase64('helper.ps1')`nvar helper = loadTextContent('helper.ps1')`n")
        $helperPath = Join-Path $script:modulePath 'helper.ps1'
        [System.IO.File]::WriteAllText($helperPath, "'#_scriptIdentifier_#'")
        $env:localToken_scriptIdentifier = 'staged-only'
        try {
            InModuleScope 'Avm.Authoring' {
                Mock Invoke-AvmBicepPolicyBaseline {
                    [System.IO.File]::ReadAllText(
                        (Join-Path $StageRoot 'avm/res/mock/widget/helper.ps1')) |
                        Should -BeExactly "'staged-only'"
                    [pscustomobject]@{
                        Source = @([pscustomobject]@{
                                File = [System.IO.Path]::GetFullPath((Join-Path $StageRoot $InputPath))
                            })
                        RuleName = 'Azure.Sample.Rule'; TargetType = 'Microsoft.Storage/storageAccounts'
                        Outcome = 'Pass'; Error = $null
                    }
                }
            }
            $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
            $result.Status | Should -Be 'pass'
            [System.IO.File]::ReadAllText($helperPath) | Should -BeExactly "'#_scriptIdentifier_#'"
        }
        finally {
            Remove-Item Env:localToken_scriptIdentifier -ErrorAction SilentlyContinue
        }
    }

    It 'fails on a missing token inside a loadTextContent reference' {
        $sourcePath = Join-Path $script:modulePath 'main.bicep'
        [System.IO.File]::AppendAllText(
            $sourcePath, "`nvar helper = loadTextContent('helper.ps1')`n")
        [System.IO.File]::WriteAllText(
            (Join-Path $script:modulePath 'helper.ps1'), "'#_scriptIdentifier_#'")
        $before = $env:localToken_scriptIdentifier
        try {
            Remove-Item Env:localToken_scriptIdentifier -ErrorAction SilentlyContinue
            $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
            $result.Status | Should -Be 'fail'
            $result.BaselinesExecuted | Should -Be 0
            $result.Issues.Code | Should -Contain 'avm.bicep.psrule-source'
            $result.Issues.Message | Should -Match 'localToken_scriptIdentifier'
        }
        finally {
            if ($null -ne $before) {
                $env:localToken_scriptIdentifier = $before
            }
        }
    }

    It 'preserves raw binary loads without treating their bytes as tokens' {
        $sourcePath = Join-Path $script:modulePath 'main.bicep'
        [System.IO.File]::AppendAllText(
            $sourcePath, "`nvar encoded = loadFileAsBase64('payload.bin')`n")
        $binaryPath = Join-Path $script:modulePath 'payload.bin'
        $bytes = [byte[]]@(255, 0, 35, 95, 120, 95, 35)
        [System.IO.File]::WriteAllBytes($binaryPath, $bytes)
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPolicyBaseline {
                $staged = [System.IO.File]::ReadAllBytes(
                    (Join-Path $StageRoot 'avm/res/mock/widget/payload.bin'))
                $staged | Should -Be ([byte[]]@(255, 0, 35, 95, 120, 95, 35))
                [pscustomobject]@{
                    Source = @([pscustomobject]@{
                            File = [System.IO.Path]::GetFullPath((Join-Path $StageRoot $InputPath))
                        })
                    RuleName = 'Azure.Sample.Rule'; TargetType = 'Microsoft.Storage/storageAccounts'
                    Outcome = 'Pass'; Error = $null
                }
            }
        }
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        [System.IO.File]::ReadAllBytes($binaryPath) | Should -Be $bytes
    }

    It 'reports required failures as errors and advisory findings as warnings' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPolicyBaseline {
                $outcome = if ($Baseline -in @('Azure.Pillar.Reliability', 'Azure.Default')) {
                    'Fail'
                }
                else { 'Pass' }
                [pscustomobject]@{
                    Source = @([pscustomobject]@{
                            File = [System.IO.Path]::GetFullPath((Join-Path $StageRoot $InputPath))
                        })
                    RuleName = 'Azure.Sample.Rule'; TargetType = 'Microsoft.Storage/storageAccounts'
                    Outcome = $outcome; Error = $null
                }
            }
        }

        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.BaselinesExecuted | Should -Be 8
        @($result.Issues | Where-Object Severity -eq 'error').Count | Should -Be 2
        @($result.Issues | Where-Object Severity -eq 'warning').Count | Should -Be 2
        $result.Issues.RuleName | Should -Contain 'Azure.Sample.Rule'
        $result.Issues.Baseline | Should -Contain 'Azure.Pillar.Reliability'
        $result.Issues.Baseline | Should -Contain 'Azure.Default'
    }

    It 'returns pass with warning issues if only advisory rules fail' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPolicyBaseline {
                [pscustomobject]@{
                    Source = @([pscustomobject]@{
                            File = [System.IO.Path]::GetFullPath((Join-Path $StageRoot $InputPath))
                        })
                    RuleName = 'Azure.Sample.Rule'; TargetType = 'Microsoft.Storage/storageAccounts'
                    Outcome = if ($Baseline -eq 'Azure.Default') { 'Fail' } else { 'Pass' }
                    Error = $null
                }
            }
        }

        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $result.Issues.Count | Should -Be 2
        $result.Issues.Severity | Should -Be @('warning', 'warning')
    }

    It 'fails closed when a required token is missing without writing the token value' {
        Remove-Item Env:TOKEN_NAMEPREFIX -ErrorAction SilentlyContinue
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.BaselinesExecuted | Should -Be 0
        $result.Issues.Code | Should -Contain 'avm.bicep.psrule-source'
        $result.Issues.Message | Should -Match 'TOKEN_NAMEPREFIX'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmBicepPolicyBaseline -Exactly 0
        }
    }

    It 'fails closed when a token in a referenced source is marked sensitive' {
        $sourcePath = Join-Path $script:modulePath 'main.bicep'
        [System.IO.File]::AppendAllText($sourcePath, "`nvar sensitive = '#_storageSecret_#'`n")
        $env:localToken_storageSecret = 'not-for-output'
        try {
            $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
            $result.Status | Should -Be 'fail'
            $result.Issues.Code | Should -Contain 'avm.bicep.psrule-source'
            $result.Issues.Message | Should -Not -Match 'not-for-output'
            $result.Issues.Message | Should -Match 'sensitive token'
        }
        finally {
            Remove-Item Env:localToken_storageSecret -ErrorAction SilentlyContinue
        }
    }

    It 'names a missing local module reference instead of silently checking an incomplete tree' {
        $test = Join-Path $script:modulePath 'tests/e2e/defaults/main.test.bicep'
        $text = [System.IO.File]::ReadAllText($test).Replace(
            '../../../main.bicep', '../../../absent.bicep')
        [System.IO.File]::WriteAllText($test, $text)

        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.BaselinesExecuted | Should -Be 4
        @($result.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.psrule-source' -and
                $_.File -eq 'tests/e2e/defaults/main.test.bicep'
            }).Count | Should -Be 1
    }

    It 'rejects local references escaping the repository' {
        $test = Join-Path $script:modulePath 'tests/e2e/defaults/main.test.bicep'
        $text = [System.IO.File]::ReadAllText($test).Replace(
            '../../../main.bicep', '../../../../../../../../outside.bicep')
        [System.IO.File]::WriteAllText($test, $text)

        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.psrule-source'
        $result.Issues.Message | Should -Match 'outside the repository'
    }

    It 'fails when an advisory baseline returns no inspectable results' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPolicyBaseline {
                if ($Baseline -eq 'Azure.Default') { return @() }
                [pscustomobject]@{
                    Source = @([pscustomobject]@{
                            File = [System.IO.Path]::GetFullPath((Join-Path $StageRoot $InputPath))
                        })
                    RuleName = 'Azure.Sample.Rule'; TargetType = 'Microsoft.Storage/storageAccounts'
                    Outcome = 'Pass'; Error = $null
                }
            }
        }
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.BaselinesExecuted | Should -Be 6
        @($result.Issues | Where-Object Code -eq 'avm.bicep.psrule-empty').Count |
            Should -Be 2
    }

    It 'does not mistake unexpanded Bicep file results for Azure resource evaluation' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPolicyBaseline {
                [pscustomobject]@{
                    Source = @([pscustomobject]@{
                            File = [System.IO.Path]::GetFullPath((Join-Path $StageRoot $InputPath))
                        })
                    RuleName = 'Azure.Sample.Rule'; TargetType = '.bicep'
                    Outcome = 'None'; Error = $null
                }
            }
        }
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.BaselinesExecuted | Should -Be 0
        @($result.Issues | Where-Object Code -eq 'avm.bicep.psrule-expansion').Count |
            Should -Be 8
    }

    It 'rejects rule results not belonging to the requested baseline' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPolicyBaseline {
                [pscustomobject]@{
                    Source = @([pscustomobject]@{
                            File = [System.IO.Path]::GetFullPath((Join-Path $StageRoot $InputPath))
                        })
                    RuleName = 'Azure.Other.Rule'; TargetType = 'Microsoft.Storage/storageAccounts'
                    Outcome = 'Pass'; Error = $null
                }
            }
        }
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.BaselinesExecuted | Should -Be 0
        @($result.Issues | Where-Object Code -eq 'avm.bicep.psrule-result').Count |
            Should -Be 8
    }

    It 'fails before evaluation if a required baseline is missing' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmBicepPolicyBaseline {
                if ($Name -eq 'CB.AVM.WAF.Security') {
                    throw [AvmConfigurationException]::new('Custom baseline is missing.')
                }
                $names = [System.Collections.Generic.HashSet[string]]::new()
                $null = $names.Add('Azure.Sample.Rule')
                [pscustomobject]@{ Name = $Name; RuleNames = $names }
            }
        }
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.BaselinesExecuted | Should -Be 0
        $result.Issues.Code | Should -Contain 'avm.bicep.psrule-baseline'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmBicepPolicyBaseline -Exactly 0
        }
    }

    It 'fails before evaluation if the optional exact-version PSRule modules are unavailable' {
        InModuleScope 'Avm.Authoring' {
            Mock Import-AvmBicepPolicyModule {
                throw [AvmConfigurationException]::new(
                    'Bicep policy requires PSRule 2.9.0. Install-PSResource -Name PSRule.')
            }
        }
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.ToolSource | Should -Be 'not-run'
        $result.Issues.Code | Should -Contain 'avm.bicep.psrule-module'
        $result.Issues.Message | Should -Match 'Install-PSResource'
    }

    It 'does not leak PSRule engine exception details and removes its temporary files' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPolicyBaseline {
                $script:stageInputs.Add([pscustomobject]@{ Root = $StageRoot })
                throw [System.InvalidOperationException]::new('do-not-echo-this-value')
            }
        }
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.BaselinesExecuted | Should -Be 0
        $result.Issues.Code | Should -Contain 'avm.bicep.psrule-evaluation'
        $result.Issues.Message | Should -Not -Match 'do-not-echo-this-value'
        InModuleScope 'Avm.Authoring' {
            foreach ($input in $script:stageInputs) {
                [System.IO.Directory]::Exists($input.Root) | Should -BeFalse
            }
        }
    }

    It 'cannot return a passing result when WhatIf prevents staging' {
        $context = Get-AvmModuleContext -Path $script:modulePath -SkipModuleVersionCheck
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $context } {
            param($C)
            Invoke-AvmBicepCheckPolicy -Context $C -WhatIf
        }
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.psrule-not-run'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmBicepPolicyBaseline -Exactly 0
        }
    }
}
