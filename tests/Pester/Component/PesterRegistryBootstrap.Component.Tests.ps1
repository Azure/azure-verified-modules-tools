#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:helperPath = Join-Path $script:repoRoot 'build' 'AvmPesterSharding.ps1'
    . $script:helperPath

    function script:Get-AvmTestResultPath {
        param([string] $Tier)
        $directory = Join-Path $script:outRoot 'test-results'
        $null = New-Item -ItemType Directory -Path $directory -Force
        Join-Path $directory "$Tier.xml"
    }

    function script:Write-Build {
        param($Color, $Text)
    }
}

Describe 'Component: Pester registry bootstrap' -Tag Component {
    BeforeEach {
        $script:outRoot = Join-Path $TestDrive 'out'
        if ($IsWindows) {
            $script:registryRoot = (Get-PSDrive TestRegistry).Root
            $script:subKey = $script:registryRoot.Substring('HKEY_CURRENT_USER\'.Length) +
                '\bootstrap-' + [guid]::NewGuid().ToString('N')
        }
    }

    It 'uses the Pester shared parent by default' {
        $parameter = (Get-Command Initialize-AvmPesterRegistryRoot).ScriptBlock.Ast.Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SubKey' }
        $parameter.DefaultValue.SafeGetValue() | Should -BeExactly 'Software\Pester'
    }

    It 'does nothing outside Windows' -Skip:$IsWindows {
        @(Initialize-AvmPesterRegistryRoot -SubKey 'unused').Count | Should -Be 0
    }

    It 'creates a missing fixture root without a check-then-create race' -Skip:(-not $IsWindows) {
        $path = "Registry::HKEY_CURRENT_USER\$script:subKey"
        Test-Path -LiteralPath $path | Should -BeFalse

        Initialize-AvmPesterRegistryRoot -SubKey $script:subKey

        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It 'reopens an existing root without replacing its values or children' -Skip:(-not $IsWindows) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:subKey)
        try {
            $key.SetValue('sentinel', 'preserve-root')
            $child = $key.CreateSubKey('existing-child')
            try { $child.SetValue('sentinel', 'preserve-child') }
            finally { $child.Dispose() }
        }
        finally { $key.Dispose() }

        Initialize-AvmPesterRegistryRoot -SubKey $script:subKey
        Initialize-AvmPesterRegistryRoot -SubKey $script:subKey

        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:subKey)
        try {
            $key.GetValue('sentinel') | Should -BeExactly 'preserve-root'
            $child = $key.OpenSubKey('existing-child')
            try { $child.GetValue('sentinel') | Should -BeExactly 'preserve-child' }
            finally { $child.Dispose() }
        }
        finally { $key.Dispose() }
    }

    It 'supports concurrent bootstrap and preserves each worker through Pester teardown' -Skip:(-not $IsWindows) {
        $path = "Registry::HKEY_CURRENT_USER\$script:subKey"
        Test-Path -LiteralPath $path | Should -BeFalse
        $helper = $script:helperPath.Replace("'", "''")
        $subKey = $script:subKey.Replace("'", "''")
        $files = @(foreach ($index in 1..4) {
                $record = (Join-Path $TestDrive "registry-$index.txt").Replace("'", "''")
                $probe = Join-Path $TestDrive "Registry-$index.Tests.ps1"
                [IO.File]::WriteAllText($probe, @"
BeforeAll { . '$helper' }
Describe 'registry worker $index' {
    It 'keeps its unique TestRegistry and the shared bootstrap key' {
        [IO.File]::WriteAllText('$record', (Get-PSDrive TestRegistry).Root)
        foreach (`$iteration in 1..32) {
            Initialize-AvmPesterRegistryRoot -SubKey '$subKey'
            `$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('$subKey', `$true)
            try { `$key.SetValue('worker-$index', 'preserved') }
            finally { `$key.Dispose() }
        }
    }
}
"@)
                Get-Item -LiteralPath $probe
            })

        $result = Invoke-AvmPesterShardedTier -Tier unit -File $files -ShardCount 4 6>$null

        $result.PassedCount | Should -Be 4
        $result.FailedCount | Should -Be 0
        $registryPaths = @(foreach ($index in 1..4) {
                $record = Get-Content -LiteralPath (Join-Path $TestDrive "registry-$index.txt") -Raw
                Test-Path -LiteralPath "Registry::$record" | Should -BeFalse
                $record
            })
        @($registryPaths | Sort-Object -Unique).Count | Should -Be 4
        Test-Path -LiteralPath "Registry::$script:registryRoot" | Should -BeTrue
        Test-Path -LiteralPath 'Registry::HKEY_CURRENT_USER\Software\Pester' | Should -BeTrue
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:subKey)
        try {
            foreach ($index in 1..4) {
                $key.GetValue("worker-$index") | Should -BeExactly 'preserved'
            }
        }
        finally { $key.Dispose() }
    }
}
