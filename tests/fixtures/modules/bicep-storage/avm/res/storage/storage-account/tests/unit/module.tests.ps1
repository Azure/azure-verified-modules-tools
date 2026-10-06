Describe 'Storage module authored unit tests' {
    It 'retains the secure default in its source' {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'main.bicep') -Raw
        $source | Should -Match 'param supportsHttpsTrafficOnly bool = true'
    }
}
