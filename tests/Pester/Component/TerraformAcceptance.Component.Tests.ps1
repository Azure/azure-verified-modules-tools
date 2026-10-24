#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Terraform acceptance byte inventory' -Tag Component {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' 'Helpers' 'TerraformAcceptance.ps1')
    }

    Describe 'Terraform acceptance public pr-check contract' -Tag Component {
        BeforeAll {
            . (Join-Path $PSScriptRoot '..' 'Helpers' 'TerraformAcceptance.ps1')
            function avm {
                throw [System.InvalidOperationException]::new('The public dispatcher must be mocked.')
            }
        }

        BeforeEach {
            $script:result = [pscustomobject]@{
                Status = 'pass'
                Steps = @(
                    foreach ($name in @('metadata', 'initialize', 'sync', 'format', 'transform', 'lint',
                            'check policy', 'check convention', 'validate', 'docs')) {
                        [pscustomobject]@{
                            Step = $name
                            Status = 'pass'
                            Error = ''
                            Result = [pscustomobject]@{ Evaluated = 1; Issues = @() }
                        }
                    }

                )
            }
            Mock Assert-TerraformAcceptanceCredentials {}
            Mock avm { $script:result }
        }

        It 'accepts all ten public steps with explicit initialization and real policy evidence' {
            $actual = Invoke-TerraformAcceptancePrCheck -Context ([pscustomobject]@{ Root = $TestDrive })

            [object]::ReferenceEquals($actual, $script:result) | Should -BeTrue
            Should -Invoke Assert-TerraformAcceptanceCredentials -Exactly 1
            Should -Invoke avm -Exactly 1
        }

        It 'rejects <Failure> in the public step contract' -ForEach @(
            @{ Failure = 'a duplicate initialization step' }
            @{ Failure = 'a missing initialization step' }
            @{ Failure = 'a failed initialization step' }
            @{ Failure = 'a skipped initialization step' }
            @{ Failure = 'a missing step' }
            @{ Failure = 'an empty policy evaluation' }
            @{ Failure = 'a policy issue' }
        ) {
            switch ($Failure) {
                'a duplicate initialization step' {
                    $script:result.Steps = @($script:result.Steps[0],
                        [pscustomobject]@{ Step = 'initialize'; Status = 'pass'; Error = '' }) +
                    $script:result.Steps[1..9]
                }
                'a missing initialization step' {
                    $script:result.Steps = @($script:result.Steps | Where-Object Step -ne 'initialize')
                }
                'a failed initialization step' { $script:result.Steps[1].Status = 'fail' }
                'a skipped initialization step' { $script:result.Steps[1].Status = 'skipped' }
                'a missing step' { $script:result.Steps = $script:result.Steps[0..8] }
                'an empty policy evaluation' { $script:result.Steps[6].Result.Evaluated = 0 }
                'a policy issue' { $script:result.Steps[6].Result.Issues = @('Policy failed.') }
            }

            { Invoke-TerraformAcceptancePrCheck -Context ([pscustomobject]@{ Root = $TestDrive }) } |
                Should -Throw
        }
    }

    Describe 'Terraform acceptance cleanup' -Tag Component {
        BeforeAll {
            . (Join-Path $PSScriptRoot '..' 'Helpers' 'TerraformAcceptance.ps1')
        }

        BeforeEach {
            $script:work = Join-Path $TestDrive ('acceptance-work-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:work
            $script:context = [pscustomobject]@{
                Work = $script:work
                Environment = @{}
            }
            Mock Start-Sleep {}
        }

        It 'retries a transient provider file lock and completes cleanup' {
            $script:attempts = 0
            Mock Remove-Item {
                $script:attempts++
                if ($script:attempts -eq 1) {
                    throw [IO.IOException]::new(
                        'The process cannot access the file because it is being used by another process.')
                }
            } -ParameterFilter { $LiteralPath -ceq $script:work -and $Recurse -and $Force -and $ErrorAction -eq 'Stop' }

            Remove-TerraformAcceptanceContext -Context $script:context

            $script:attempts | Should -Be 2
            Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Milliseconds -eq 100 }
        }

        It 'rethrows the final transient provider file lock after bounded retries' {
            $script:attempts = 0
            Mock Remove-Item {
                $script:attempts++
                throw [IO.IOException]::new(
                    'The process cannot access the file because it is being used by another process.')
            } -ParameterFilter { $LiteralPath -ceq $script:work -and $Recurse -and $Force -and $ErrorAction -eq 'Stop' }

            { Remove-TerraformAcceptanceContext -Context $script:context } |
                Should -Throw -ExceptionType ([IO.IOException]) -ExpectedMessage '*being used by another process*'

            $script:attempts | Should -Be 5
            Should -Invoke Start-Sleep -Exactly 4
        }

        It 'rethrows non-retryable cleanup failures immediately' {
            $script:attempts = 0
            Mock Remove-Item {
                $script:attempts++
                throw [UnauthorizedAccessException]::new('Cleanup access denied.')
            } -ParameterFilter { $LiteralPath -ceq $script:work -and $Recurse -and $Force -and $ErrorAction -eq 'Stop' }

            { Remove-TerraformAcceptanceContext -Context $script:context } |
                Should -Throw -ExceptionType ([UnauthorizedAccessException]) -ExpectedMessage '*Cleanup access denied.*'

            $script:attempts | Should -Be 1
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    BeforeEach {
        Mock Invoke-TerraformAcceptanceGit {
            [pscustomobject]@{ StdOut = 'diff --git a/main.tf b/main.tf' }
        }
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:root
        foreach ($fileName in @('main.tf', 'README.md', '.env', '.gitignore', '.terraform.lock.hcl')) {
            [IO.File]::WriteAllText((Join-Path $script:root $fileName), "original $fileName`n")
        }
        $script:before = Get-TerraformAcceptanceFiles -Root $script:root
        $script:context = [pscustomobject]@{
            Root = $script:root
            ConfigurationDirectories = @('', 'examples/default')
        }
    }

    It 'includes the native diff when rejecting changed authored bytes' {
        [IO.File]::WriteAllText((Join-Path $script:root 'main.tf'), "changed`n")
        { Assert-TerraformAcceptanceFiles -Context $script:context -Expected $script:before } |
            Should -Throw '*modified: main.tf*diff --git a/main.tf b/main.tf*'
        Should -Invoke Invoke-TerraformAcceptanceGit -Exactly 1 -ParameterFilter {
            $Arguments -join ' ' -ceq 'diff --no-ext-diff --no-color --'
        }
    }

    It 'creates native Windows test module cache parents before fixture initialization' -Skip:(-not $IsWindows) {
        $manifest = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module -Name $manifest -Force
        $context = $null
        try {
            Mock Resolve-AvmTool -ModuleName Avm.Authoring { [pscustomobject]@{ Path = 'fixture-terraform' } }
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                $parent = Join-Path $WorkingDirectory '.terraform' 'modules' 'test.tests' 'unit'
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                    throw [IO.DirectoryNotFoundException]::new('Native test module cache parent is absent.')
                }
                [pscustomobject]@{ StdOut = '' }
            }
            $context = New-TerraformAcceptanceContext -Source $script:root -Name 'windows-bootstrap' -InitializeLock
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                $ArgumentList -join ' ' -ceq 'init -backend=false -input=false -no-color -test-directory=tests/unit'
            }
            @($context.Authored.Keys | Where-Object { $_ -like '.terraform/*' }) | Should -HaveCount 0
        }
        finally {
            if ($null -ne $context) { Remove-TerraformAcceptanceContext -Context $context }
            Remove-Module Avm.Authoring -Force
        }
    }

    It 'detects modified, deleted and added authored bytes including dotfiles and tracked locks: <Name>' -ForEach @(
        @{ Name = 'main.tf' }
        @{ Name = 'README.md' }
        @{ Name = '.env' }
        @{ Name = '.gitignore' }
        @{ Name = '.terraform.lock.hcl' }
    ) {
        $path = Join-Path $script:root $Name
        [IO.File]::WriteAllText($path, "changed`n")
        { Assert-TerraformAcceptanceFiles -Context $script:context -Expected $script:before } |
            Should -Throw "*modified: $Name*"
        Remove-Item -LiteralPath $path -Force
        { Assert-TerraformAcceptanceFiles -Context $script:context -Expected $script:before } |
            Should -Throw "*deleted: $Name*"
        $after = Get-TerraformAcceptanceFiles -Root $script:root
        [IO.File]::WriteAllText($path, "new`n")
        $script:context.ConfigurationDirectories = @()
        { Assert-TerraformAcceptanceFiles -Context $script:context -Expected $after } |
            Should -Throw "*added: $Name*"
    }

    It 'allows only new configuration locks, Terraform working data and root Git metadata' {
        foreach ($relative in @('.git\index', 'examples\default\.terraform.lock.hcl',
                'examples\default\.terraform\modules\modules.json')) {
            $path = Join-Path $script:root $relative
            $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
            [IO.File]::WriteAllText($path, 'tool-owned')
        }
        Assert-TerraformAcceptanceFiles -Context $script:context -Expected $script:before
        $path = Join-Path $script:root '.new-owner-file'
        [IO.File]::WriteAllText($path, 'not a transient')
        { Assert-TerraformAcceptanceFiles -Context $script:context -Expected $script:before } |
            Should -Throw '*added: .new-owner-file*'
    }

    It 'does not exempt unexpected locks or tracked files in a tool-like directory' {
        $path = Join-Path $script:root 'authored\.terraform.lock.hcl'
        $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent)
        [IO.File]::WriteAllText($path, 'unexpected')
        { Assert-TerraformAcceptanceFiles -Context $script:context -Expected $script:before } |
            Should -Throw '*added: authored/.terraform.lock.hcl*'

        $tracked = Join-Path $script:root '.terraform\authored.tf'
        $null = New-Item -ItemType Directory -Path (Split-Path $tracked -Parent)
        [IO.File]::WriteAllText($tracked, 'tracked')
        $expected = Get-TerraformAcceptanceFiles -Root $script:root
        $expected['.terraform/authored.tf'] = (Get-FileHash -LiteralPath $tracked).Hash
        [IO.File]::WriteAllText($tracked, 'changed')
        { Assert-TerraformAcceptanceFiles -Context $script:context -Expected $expected } |
            Should -Throw '*modified: .terraform/authored.tf*'
    }

    It 'rejects skipped, missing and reordered public steps rather than accepting an overall pass' {
        $steps = @(
            [pscustomobject]@{ Step = 'initialize'; Status = 'pass'; Error = '' }
            [pscustomobject]@{ Step = 'validate'; Status = 'skipped'; Error = '' }
        )
        $result = [pscustomobject]@{ Status = 'pass'; Steps = $steps }
        { Assert-TerraformAcceptanceSteps -Result $result -Names @('initialize', 'validate') } | Should -Throw
        $steps[1].Status = 'pass'
        { Assert-TerraformAcceptanceSteps -Result $result -Names @('validate', 'initialize') } | Should -Throw
        { Assert-TerraformAcceptanceSteps -Result $result -Names @('initialize', 'validate', 'docs') } | Should -Throw
        Assert-TerraformAcceptanceSteps -Result $result -Names @('initialize', 'validate')
    }
}
