#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    $script:scriptPath = Join-Path $script:repoRoot 'scripts' 'Publish-AvmAuthoring.ps1'
    $script:parseTokens = $null
    $script:parseErrors = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:scriptPath,
        [ref] $script:parseTokens,
        [ref] $script:parseErrors
    )
}

Describe 'Publish-AvmAuthoring.ps1 security contract' {
    It 'parses without errors' {
        @($script:parseErrors).Count | Should -Be 0
    }

    It 'accepts the Gallery API key only as SecureString' {
        $apiKeyParameter = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ApiKey' } |
            Select-Object -First 1

        $apiKeyParameter | Should -Not -BeNullOrEmpty
        $apiKeyParameter.StaticType.FullName | Should -Be 'System.Security.SecureString'
    }

    It 'converts the key only at the Publish-PSResource boundary' {
        $commands = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true))

        $commands.GetCommandName() | Should -Contain 'ConvertFrom-SecureString'
        $commands.GetCommandName() | Should -Contain 'Publish-PSResource'
        $script:ast.Extent.Text | Should -Match '(?s)finally\s*\{\s*\$plainApiKey\s*=\s*\$null'
    }
}
