#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    function script:New-E2eFixture {
        param([hashtable] $Example = @{})

        $root = Join-Path $TestDrive ('e2e-fx-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        foreach ($name in $Example.Keys) {
            $dir = Join-Path $root 'examples' $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $spec = $Example[$name]
            if ($spec.ContainsKey('Tf') -and $spec['Tf']) {
                Set-Content -LiteralPath (Join-Path $dir 'main.tf') -Value '# example' -Encoding utf8
            }
            if ($spec.ContainsKey('Ignore') -and $spec['Ignore']) {
                Set-Content -LiteralPath (Join-Path $dir '.e2eignore') -Value '' -Encoding utf8
            }
        }
        $root
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmTerraformE2eExample' {
    It 'returns an empty set when examples/ is absent' {
        $root = New-E2eFixture
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            @(Get-AvmTerraformE2eExample -Root $R)
        }
        @($result).Count | Should -Be 0
    }

    It 'ignores directories that contain no .tf files' {
        $root = New-E2eFixture -Example @{
            'real'  = @{ Tf = $true }
            'empty' = @{ Tf = $false }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            @(Get-AvmTerraformE2eExample -Root $R)
        }
        @($result).Name | Should -Be @('real')
    }

    It 'flags .e2eignore directories instead of dropping them' {
        $root = New-E2eFixture -Example @{
            'alpha'   = @{ Tf = $true }
            'skipped' = @{ Tf = $true; Ignore = $true }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            @(Get-AvmTerraformE2eExample -Root $R)
        }
        @($result).Name | Should -Be @('alpha', 'skipped')
        ($result | Where-Object Name -EQ 'skipped').Ignored | Should -BeTrue
        ($result | Where-Object Name -EQ 'alpha').Ignored   | Should -BeFalse
    }
}

Describe 'Select-AvmTerraformE2eExample' {
    BeforeEach {
        $script:available = @(
            [pscustomobject]@{ Name = 'example-a'; Path = '/m/examples/example-a'; Ignored = $false }
            [pscustomobject]@{ Name = 'example-b'; Path = '/m/examples/example-b'; Ignored = $false }
            [pscustomobject]@{ Name = 'skipped'; Path = '/m/examples/skipped'; Ignored = $true }
        )
    }

    It 'returns every runnable example when no selector is supplied' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $script:available } {
            param($A)
            @(Select-AvmTerraformE2eExample -Example $A)
        }
        @($result).Name | Should -Be @('example-a', 'example-b')
    }

    It 'normalises <selector> to the example leaf' -TestCases @(
        @{ Selector = 'example-a' }
        @{ Selector = 'examples/example-a' }
        @{ Selector = './examples/example-a' }
        @{ Selector = 'examples\example-a' }
        @{ Selector = 'examples/example-a/' }
    ) {
        param($Selector)
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $script:available; S = $Selector } {
            param($A, $S)
            @(Select-AvmTerraformE2eExample -Example $A -Selector $S)
        }
        @($result).Name | Should -Be @('example-a')
    }

    It 'de-duplicates repeated selectors' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $script:available } {
            param($A)
            @(Select-AvmTerraformE2eExample -Example $A -Selector @('example-a', 'examples/example-a'))
        }
        @($result).Count | Should -Be 1
    }

    It 'throws AvmConfigurationException listing valid names for an unknown example' {
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ A = $script:available } {
                param($A)
                Select-AvmTerraformE2eExample -Example $A -Selector 'exampel-a'
            }
        }
        catch { $err = $_.Exception }

        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message        | Should -Match "Unknown e2e example 'exampel-a'"
        $err.Message        | Should -Match 'example-a, example-b'
    }

    It 'throws AvmConfigurationException when an explicitly named example carries .e2eignore' {
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ A = $script:available } {
                param($A)
                Select-AvmTerraformE2eExample -Example $A -Selector 'skipped'
            }
        }
        catch { $err = $_.Exception }

        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message        | Should -Match '\.e2eignore'
    }
}
