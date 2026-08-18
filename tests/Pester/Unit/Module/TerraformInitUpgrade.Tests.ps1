#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:productionRoots = @(
        (Join-Path $script:repoRoot 'src')
        (Join-Path $script:repoRoot 'repository-management')
    )
}

Describe 'Terraform init upgrade guard' {
    It 'requires -upgrade in every production init argument construction' {
        $sites = foreach ($file in Get-ChildItem -LiteralPath $script:productionRoots -Recurse -File -Filter '*.ps1') {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName,
                [ref]$tokens,
                [ref]$parseErrors
            )
            $parseErrors | Should -BeNullOrEmpty -Because $file.FullName

            foreach ($literal in $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                        $node.Value -eq 'init'
                    }, $true)) {
                $container = $literal.Parent
                while (
                    $null -ne $container -and
                    $container -isnot [System.Management.Automation.Language.ArrayLiteralAst] -and
                    $container -isnot [System.Management.Automation.Language.FunctionDefinitionAst]
                ) {
                    $container = $container.Parent
                }

                $hasUpgrade = if ($container -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                    @($container.FindAll({
                                param($node)
                                $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                                $node.Value -eq '-upgrade'
                            }, $true)).Count -gt 0
                }
                elseif ($container -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $container.Extent.Text -match '\.Add\(\s*[''"]-upgrade[''"]\s*\)'
                }
                else {
                    $false
                }

                [pscustomobject]@{
                    File       = [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName)
                    Line       = $literal.Extent.StartLineNumber
                    HasUpgrade = $hasUpgrade
                }
            }
        }

        $sites | Should -Not -BeNullOrEmpty
        @($sites | Where-Object { -not $_.HasUpgrade }) |
            Should -BeNullOrEmpty -Because (
                'every production Terraform init must use -upgrade; discovered sites: ' +
                (($sites | ForEach-Object { '{0}:{1}' -f $_.File, $_.Line }) -join ', ')
            )
    }

    It 'does not disable init upgrade in production PowerShell' {
        $matches = @(
            Get-ChildItem -LiteralPath $script:productionRoots -Recurse -File -Filter '*.ps1' |
                Select-String -SimpleMatch '-upgrade=false'
        )
        $matches | Should -BeNullOrEmpty
    }
}
