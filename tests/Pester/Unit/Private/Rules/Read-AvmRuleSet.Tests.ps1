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
}

Describe 'Read-AvmRuleSet loader' {
    It 'returns the built-in smoke rule when there is no per-repo override' {
        $root = script:NewRoot
        $rules = InModuleScope 'Avm.Authoring' -Parameters @{ P = $root } { param($P) Read-AvmRuleSet -Path $P }
        @($rules).Count | Should -BeGreaterOrEqual 1
        ($rules | Where-Object Id -eq 'avm.smoke.avm-config-exists') | Should -Not -BeNullOrEmpty
        $rules[0].Source | Should -Match 'Resources[\\/]Rules[\\/]'
    }

    It 'lets a per-repo .avm/rules/*.psd1 override a built-in rule by Id' {
        $root = script:NewRoot
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir | Out-Null

        # Override the smoke rule with an upgraded Severity.
        script:WriteRuleFile (Join-Path $repoDir 'override.psd1') @'
@{
    Id          = 'avm.smoke.avm-config-exists'
    Kind        = 'FileMustExist'
    Description = 'OVERRIDDEN: harder line on config'
    Severity    = 'error'
    AppliesTo   = 'root'
    Parameters  = @{ Path = '.avm/config.json' }
}
'@

        $rules = InModuleScope 'Avm.Authoring' -Parameters @{ P = $root } { param($P) Read-AvmRuleSet -Path $P }
        $smoke = $rules | Where-Object Id -eq 'avm.smoke.avm-config-exists'
        $smoke.Severity | Should -Be 'error'
        $smoke.Description | Should -Match 'OVERRIDDEN'
        $smoke.Source | Should -Be (Join-Path $repoDir 'override.psd1')
    }

    It 'appends a per-repo rule whose Id does not collide with a built-in' {
        $root = script:NewRoot
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir | Out-Null

        script:WriteRuleFile (Join-Path $repoDir 'custom.psd1') @'
@{
    Id          = 'avm.repo.custom-no-foo'
    Kind        = 'FileMustNotExist'
    Description = 'foo.tf is banned'
    Parameters  = @{ Path = 'foo.tf' }
}
'@

        $rules = InModuleScope 'Avm.Authoring' -Parameters @{ P = $root } { param($P) Read-AvmRuleSet -Path $P }
        ($rules | Where-Object Id -eq 'avm.repo.custom-no-foo') | Should -Not -BeNullOrEmpty
        ($rules | Where-Object Id -eq 'avm.smoke.avm-config-exists') | Should -Not -BeNullOrEmpty
    }

    It 'returns rules sorted by Id (ordinal)' {
        $root = script:NewRoot
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir | Out-Null

        script:WriteRuleFile (Join-Path $repoDir 'z.psd1') @'
@{ Id='avm.zeta'; Kind='FileMustExist'; Description='z'; Parameters=@{ Path='z' } }
'@
        script:WriteRuleFile (Join-Path $repoDir 'a.psd1') @'
@{ Id='avm.alpha'; Kind='FileMustExist'; Description='a'; Parameters=@{ Path='a' } }
'@

        $rules = InModuleScope 'Avm.Authoring' -Parameters @{ P = $root } { param($P) Read-AvmRuleSet -Path $P }
        $ids = @($rules.Id)
        $sorted = $ids | Sort-Object {$_}
        # Confirm the loader sorts (ordinal) — alpha comes before smoke comes before zeta.
        ($ids.IndexOf('avm.alpha'))                    | Should -BeLessThan ($ids.IndexOf('avm.smoke.avm-config-exists'))
        ($ids.IndexOf('avm.smoke.avm-config-exists'))  | Should -BeLessThan ($ids.IndexOf('avm.zeta'))
    }

    It 'throws AvmConfigurationException with the file path when a .psd1 is malformed' {
        $root = script:NewRoot
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir | Out-Null

        $bad = Join-Path $repoDir 'busted.psd1'
        script:WriteRuleFile $bad 'this is not valid powershell data { @ } @'

        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $root } { param($P) Read-AvmRuleSet -Path $P }
        }
        catch {
            $err = $_.Exception
        }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message | Should -Match ([regex]::Escape($bad))
    }

    It 'throws AvmConfigurationException when a .psd1 declares an array (not hashtable)' {
        $root = script:NewRoot
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir | Out-Null

        $bad = Join-Path $repoDir 'array.psd1'
        script:WriteRuleFile $bad "@('not','a','hashtable')`n"

        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $root } { param($P) Read-AvmRuleSet -Path $P }
        }
        catch {
            $err = $_.Exception
        }
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        # Import-PowerShellDataFile itself rejects @(...) shapes with a parse-stage
        # error, which our loader wraps as "unable to load rule definition: ...".
        # An input that parses but isn't a hashtable (e.g. a single string) would
        # fall through to our second branch ("must declare a single top-level
        # hashtable"). Either path is correct; assert on the joining "rule" wording
        # so the test stays robust to either branch firing.
        $err.Message | Should -Match 'rule'
    }

    It 'throws AvmConfigurationException when a rule fails schema validation' {
        $root = script:NewRoot
        $repoDir = Join-Path (Join-Path $root '.avm') 'rules'
        New-Item -ItemType Directory -Path $repoDir | Out-Null

        $bad = Join-Path $repoDir 'badrule.psd1'
        script:WriteRuleFile $bad @'
@{ Id='avm.bad.kind'; Kind='SomethingMadeUp'; Description='nope'; Parameters=@{ Path='x' } }
'@

        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $root } { param($P) Read-AvmRuleSet -Path $P }
        }
        catch {
            $err = $_.Exception
        }
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message | Should -Match ([regex]::Escape($bad))
        $err.Message | Should -Match "Kind 'SomethingMadeUp'"
    }
}
