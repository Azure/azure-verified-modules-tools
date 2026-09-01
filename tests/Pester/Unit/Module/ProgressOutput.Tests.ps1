#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:buildPath = Join-Path $script:repoRoot 'build' 'avm.build.ps1'
    $script:productionFiles = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $script:repoRoot 'src' 'Avm.Authoring') `
            -Recurse `
            -File |
            Where-Object { $_.Extension -in @('.ps1', '.psm1') }
        Get-Item -LiteralPath $script:buildPath
        Get-Item -LiteralPath (Join-Path $script:repoRoot 'scripts' 'Publish-AvmAuthoring.ps1')
        Get-Item -LiteralPath (Join-Path $script:repoRoot 'scripts' 'Update-AvmPins.ps1')
    )
}

Describe 'PowerShell progress output' {
    It 'suppresses progress throughout the build task graph' {
        $buildText = Get-Content -LiteralPath $script:buildPath -Raw

        $buildText |
            Should -Match "(?m)^\`$ProgressPreference = 'SilentlyContinue'$"
    }

    It 'suppresses progress on every recursive production removal' {
        $removalCount = 0
        $unsuppressed = foreach ($file in $script:productionFiles) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName,
                [ref]$tokens,
                [ref]$parseErrors
            )
            $parseErrors | Should -BeNullOrEmpty -Because $file.FullName

            foreach ($command in $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Remove-Item'
                    }, $true)) {
                $elements = @($command.CommandElements | ForEach-Object { $_.Extent.Text })
                if ('-Recurse' -notin $elements) {
                    continue
                }

                $removalCount++
                $progressIndex = [array]::IndexOf($elements, '-ProgressAction')
                if (
                    $progressIndex -lt 0 -or
                    $progressIndex + 1 -ge $elements.Count -or
                    $elements[$progressIndex + 1] -ne 'SilentlyContinue'
                ) {
                    '{0}:{1}' -f $file.FullName, $command.Extent.StartLineNumber
                }
            }
        }

        $removalCount | Should -BeGreaterThan 0
        $unsuppressed |
            Should -BeNullOrEmpty -Because 'recursive internal cleanup must not render progress bars'
    }
}
