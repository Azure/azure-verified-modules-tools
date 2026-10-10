#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:publicPath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Public'
}

Describe 'Module version opt-out forwarding' {
    It 'checks the version once with the explicit opt-out before resolving internal module context' {
        $calls = @(
            foreach ($file in Get-ChildItem -LiteralPath $script:publicPath -File -Filter '*.ps1') {
                $tokens = $null
                $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                    $file.FullName, [ref]$tokens, [ref]$errors)
                $errors | Should -BeNullOrEmpty -Because $file.FullName
                $versionChecks = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -ceq 'Test-AvmModuleVersion'
                }, $true))

                foreach ($call in $ast.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.CommandAst] -and
                            $node.GetCommandName() -cin @('Get-AvmModuleContext', 'Get-AvmModuleContextInternal')
                        }, $true)) {
                    [pscustomobject]@{
                        File = $file.Name
                        UsesInternalContext = $call.GetCommandName() -ceq 'Get-AvmModuleContextInternal'
                        ChecksVersionOnce = $versionChecks.Count -eq 1 -and
                            $versionChecks[0].Extent.StartOffset -lt $call.Extent.StartOffset -and
                            $versionChecks[0].Extent.Text -cmatch '-SkipModuleVersionCheck:\$SkipModuleVersionCheck\b'
                    }
                }
            }
        )

        $calls.Count | Should -BeGreaterThan 10
        @($calls | Where-Object { -not $_.UsesInternalContext -or -not $_.ChecksVersionOnce } |
            Select-Object -ExpandProperty File) | Should -BeNullOrEmpty `
            -Because 'context resolution must not repeat the public version check or ignore its opt-out'
    }
}
