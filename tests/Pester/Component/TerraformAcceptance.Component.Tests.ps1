#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Terraform acceptance byte inventory' -Tag Component {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' 'Helpers' 'TerraformAcceptance.ps1')
    }

    BeforeEach {
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
        Remove-Item -LiteralPath $path
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
