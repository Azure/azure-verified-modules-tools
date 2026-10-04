#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep PSRule token replacement' {
    It 'replaces exact tokens in source text without interpreting replacement metacharacters' {
        $text = InModuleScope 'Avm.Authoring' {
            ConvertTo-AvmBicepPolicyText -Text "'#_namePrefix_#'; '#_local.name_#'" `
                -Tokens @{ namePrefix = 'prefix$1'; 'local.name' = 'local\value' }
        }
        $text | Should -BeExactly "'prefix`$1'; 'local\value'"
    }

    It 'fails rather than leaving an unknown token in place' {
        {
            InModuleScope 'Avm.Authoring' {
                ConvertTo-AvmBicepPolicyText -Text "'#_custom.unknown_#'" -Tokens @{}
            }
        } | Should -Throw '*localToken_custom.unknown*'
    }

    It 'rejects unresolved token fragments and nested tokens in replacement values' {
        {
            InModuleScope 'Avm.Authoring' {
                ConvertTo-AvmBicepPolicyText -Text "'#_namePrefix_#'" `
                    -Tokens @{ namePrefix = '#_other_#' }
            }
        } | Should -Throw '*unresolved token*'
        {
            InModuleScope 'Avm.Authoring' {
                ConvertTo-AvmBicepPolicyText -Text "'#_not-closed'" -Tokens @{}
            }
        } | Should -Throw '*unresolved token*'
    }

    It 'refuses to stage a credential-like token even if it has a supplied value' {
        {
            InModuleScope 'Avm.Authoring' {
                ConvertTo-AvmBicepPolicyText -Text "'#_apiKey_#'" `
                    -Tokens @{ apiKey = 'fixture-only' }
            }
        } | Should -Throw '*sensitive token*'
    }

    It 'allows a local non-sensitive token to override the default name prefix' {
        $before = $env:TOKEN_NAMEPREFIX
        $localBefore = $env:localToken_namePrefix
        try {
            $env:TOKEN_NAMEPREFIX = 'global'
            $env:localToken_namePrefix = 'local'
            $token = InModuleScope 'Avm.Authoring' {
                (Get-AvmBicepPolicyToken)['namePrefix']
            }
            $token | Should -BeExactly 'local'
        }
        finally {
            if ($null -eq $before) {
                Remove-Item Env:TOKEN_NAMEPREFIX -ErrorAction SilentlyContinue
            }
            else { $env:TOKEN_NAMEPREFIX = $before }
            if ($null -eq $localBefore) {
                Remove-Item Env:localToken_namePrefix -ErrorAction SilentlyContinue
            }
            else { $env:localToken_namePrefix = $localBefore }
        }
    }


    Context 'subscription token source' {
        BeforeEach {
            $script:savedTokenEnvironment = @{}
            foreach ($name in @('TEST_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_ID', 'localToken_subscriptionId')) {
                $script:savedTokenEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, [NullString]::Value)
            }
        }

        AfterEach {
            foreach ($name in $script:savedTokenEnvironment.Keys) {
                $saved = $script:savedTokenEnvironment[$name]
                [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $saved) { [NullString]::Value } else { $saved }))
            }
        }

        It 'uses the first authored pool entry even without a fallback subscription' {
            $env:TEST_SUBSCRIPTION_IDS = '[{"id":"22222222-2222-4222-8222-222222222222","name":"b"},{"id":"11111111-1111-4111-8111-111111111111","name":"a"}]'
            $env:VALIDATE_SUBSCRIPTION_ID = '33333333-3333-4333-8333-333333333333'
            InModuleScope 'Avm.Authoring' { (Get-AvmBicepPolicyToken)['subscriptionId'] } |
                Should -BeExactly '22222222-2222-4222-8222-222222222222'
        }

        It 'uses the validation subscription only when no pool is configured' {
            $env:VALIDATE_SUBSCRIPTION_ID = '33333333-3333-4333-8333-333333333333'
            InModuleScope 'Avm.Authoring' { (Get-AvmBicepPolicyToken)['subscriptionId'] } |
                Should -BeExactly '33333333-3333-4333-8333-333333333333'
        }

        It 'rejects a configured pool that is <Label>' -ForEach @(
            @{ Label = 'whitespace'; Pool = '  ' }
            @{ Label = 'not an array'; Pool = '{"id":"22222222-2222-4222-8222-222222222222","name":"b"}' }
            @{ Label = 'missing a GUID'; Pool = '[{"id":"not-a-guid","name":"b"}]' }
        ) {
            $env:TEST_SUBSCRIPTION_IDS = $Pool
            $env:VALIDATE_SUBSCRIPTION_ID = '33333333-3333-4333-8333-333333333333'
            InModuleScope 'Avm.Authoring' {
                try { $null = Get-AvmBicepPolicyToken; 'no error' }
                catch { $_.Exception.GetType().Name }
            } | Should -BeExactly 'AvmConfigurationException'
        }

        It 'keeps an explicit local subscription override' {
            $env:TEST_SUBSCRIPTION_IDS = '[{"id":"22222222-2222-4222-8222-222222222222","name":"b"}]'
            $env:localToken_subscriptionId = '44444444-4444-4444-8444-444444444444'
            InModuleScope 'Avm.Authoring' { (Get-AvmBicepPolicyToken)['subscriptionId'] } |
                Should -BeExactly '44444444-4444-4444-8444-444444444444'
        }
    }
}

Describe 'Bicep PSRule configuration boundaries' {
    It 'refuses repository scripts in the PSRule suppression directory' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $folder = Join-Path $root 'utilities' 'pipelines' 'staticValidation' 'psrule'
        $rules = Join-Path $folder '.ps-rule'
        $null = New-Item -ItemType Directory -Path $rules -Force
        [System.IO.File]::WriteAllText((Join-Path $folder 'ps-rule.yaml'), 'unused')
        [System.IO.File]::WriteAllText((Join-Path $rules 'local.Rule.ps1'), 'throw')

        {
            InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
                param($Root)
                Get-AvmBicepPolicyConfiguration -RepositoryRoot $Root
            }
        } | Should -Throw '*regular .Rule.yaml files*'
    }
}

Describe 'Bicep PSRule result inspection' {
    BeforeEach {
        $script:source = Join-Path $TestDrive 'main.test.bicep'
        $script:baseline = [pscustomobject]@{
            Name = 'Azure.Pillar.Reliability'
            RuleNames = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal)
        }
        $null = $script:baseline.RuleNames.Add('Azure.Sample.Rule')
    }

    It 'accepts inspected records only when an Azure target was expanded' {
        $record = [pscustomobject]@{
            RuleName = 'Azure.Sample.Rule'; Outcome = 'Pass'
            TargetType = 'Microsoft.Storage/storageAccounts'; Error = $null
            Source = @([pscustomobject]@{ File = $script:source })
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            R = $record; B = $script:baseline; F = $script:source; Root = $TestDrive
        } {
            param($R, $B, $F, $Root)
            ConvertFrom-AvmBicepPolicyResult -Records @($R) -Baseline $B `
                -StagePath $F -SourcePath $F -ModuleRoot $Root
        }
        $result.Valid | Should -BeTrue
        $result.ExpandedRecords | Should -Be 1
        $result.ProcessedRules | Should -Be 1
        $result.Issues.Count | Should -Be 0
    }

    It 'rejects a record attributed to a different source' {
        $record = [pscustomobject]@{
            RuleName = 'Azure.Sample.Rule'; Outcome = 'Pass'
            TargetType = 'Microsoft.Storage/storageAccounts'; Error = $null
            Source = @([pscustomobject]@{ File = (Join-Path $TestDrive 'other.bicep') })
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            R = $record; B = $script:baseline; F = $script:source; Root = $TestDrive
        } {
            param($R, $B, $F, $Root)
            ConvertFrom-AvmBicepPolicyResult -Records @($R) -Baseline $B `
                -StagePath $F -SourcePath $F -ModuleRoot $Root
        }
        $result.Valid | Should -BeFalse
        $result.Issues.Code | Should -Contain 'avm.bicep.psrule-result'
    }

    It 'rejects rule errors and uninspectable outcomes' {
        $record = [pscustomobject]@{
            RuleName = 'Azure.Sample.Rule'; Outcome = 'Error'
            TargetType = 'Microsoft.Storage/storageAccounts'
            Source = @([pscustomobject]@{ File = $script:source })
            Error = [System.InvalidOperationException]::new('fixture failure')
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            R = $record; B = $script:baseline; F = $script:source; Root = $TestDrive
        } {
            param($R, $B, $F, $Root)
            ConvertFrom-AvmBicepPolicyResult -Records @($R) -Baseline $B `
                -StagePath $F -SourcePath $F -ModuleRoot $Root
        }
        $result.Valid | Should -BeFalse
        $result.Issues.Code | Should -Contain 'avm.bicep.psrule-result'
    }
}
