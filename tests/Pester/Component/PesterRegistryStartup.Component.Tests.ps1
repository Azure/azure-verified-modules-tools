#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $repoRoot 'build' 'AvmPesterSharding.ps1')
    $script:originalTestPath = Get-Command -Name 'Microsoft.PowerShell.Management\Test-Path' -CommandType Cmdlet
    $script:originalNewItem = Get-Command -Name 'Microsoft.PowerShell.Management\New-Item' -CommandType Cmdlet
}

Describe 'Component: Pester registry initialization' -Tag 'Component' {
    It 'recovers from a native existing-key error without replacing registry data' -Skip:(-not $IsWindows) {
        $script:sharedRegistryPath = 'Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Software\Pester'
        $script:ownedRegistryPath = Join-Path 'TestRegistry:' 'collision'
        $null = New-Item -Path $script:ownedRegistryPath -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $script:ownedRegistryPath -Name 'Sentinel' -Value 'preserved' -ErrorAction Stop
        $script:registryProbes = 0

        Mock Test-Path { & $script:originalTestPath @PesterBoundParameters }
        Mock Test-Path { ++$script:registryProbes -gt 1 } -ParameterFilter {
            $LiteralPath -eq $script:sharedRegistryPath
        }
        Mock New-Item { & $script:originalNewItem @PesterBoundParameters }
        Mock New-Item {
            & $script:originalNewItem -Path $script:ownedRegistryPath -ErrorAction Stop
        } -ParameterFilter { $Path -eq $script:sharedRegistryPath }
        Mock Start-Sleep {}
        Mock Write-Information {}

        Initialize-AvmPesterRegistry

        Should -Invoke Test-Path -Exactly 2 -ParameterFilter { $LiteralPath -eq $script:sharedRegistryPath }
        Should -Invoke New-Item -Exactly 1 -ParameterFilter {
            $Path -eq $script:sharedRegistryPath -and -not $Force
        }
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Milliseconds -eq 100 }
        Should -Invoke Write-Information -Exactly 1
        (Get-ItemProperty -LiteralPath $script:ownedRegistryPath -Name 'Sentinel').Sentinel | Should -Be 'preserved'
    }
}
