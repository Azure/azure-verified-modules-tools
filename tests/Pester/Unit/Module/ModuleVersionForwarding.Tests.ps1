#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:publicPath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Public'
}

Describe 'Module version opt-out forwarding' {
    It 'passes the explicit opt-out to every nested public module context lookup' {
        $calls = @(
            foreach ($file in Get-ChildItem -LiteralPath $script:publicPath -File -Filter '*.ps1') {
                $tokens = $null
                $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                    $file.FullName, [ref]$tokens, [ref]$errors)
                $errors | Should -BeNullOrEmpty -Because $file.FullName

                foreach ($call in $ast.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.CommandAst] -and
                            $node.GetCommandName() -ceq 'Get-AvmModuleContext'
                        }, $true)) {
                    [pscustomobject]@{
                        File = $file.Name
                        ForwardsSkip = $call.Extent.Text -cmatch '-SkipModuleVersionCheck:\$SkipModuleVersionCheck\b'
                    }
                }
            }
        )

        $calls.Count | Should -BeGreaterThan 10
        @($calls | Where-Object { -not $_.ForwardsSkip } | Select-Object -ExpandProperty File) |
            Should -BeNullOrEmpty -Because 'an explicit source-preview opt-out must reach every nested module context'
    }
}
