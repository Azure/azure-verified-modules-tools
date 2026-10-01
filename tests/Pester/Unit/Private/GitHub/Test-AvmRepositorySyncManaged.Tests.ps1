#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Test-AvmRepositorySyncManaged' {
    It 'is <Expected> when the repository rulesets are <Names>' -TestCases @(
        @{ Names = @('Azure Verified Modules', 'Only allow v tags'); Expected = $true }
        @{ Names = @('azure verified modules'); Expected = $false }
        @{ Names = @(); Expected = $false }
    ) {
        param($Names, $Expected)
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Names = $Names } {
            param($Names)
            Mock Invoke-AvmGitHubApi -MockWith ({ foreach ($name in $Names) { @{ name = $name } } }.GetNewClosure())
            Test-AvmRepositorySyncManaged -Repository 'Azure/repo'
            Should -Invoke Invoke-AvmGitHubApi -Exactly 1 -ParameterFilter {
                $Endpoint -eq 'repos/Azure/repo/rulesets?includes_parents=false&per_page=100'
            }
        }
        $result | Should -Be $Expected
    }
}
