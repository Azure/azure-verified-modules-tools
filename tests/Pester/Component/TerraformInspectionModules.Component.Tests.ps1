#Requires -Version 7.4

BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    Import-Module -Name $manifest -Force

    function New-InspectionCacheFixture {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + ' space, equals=value')
        $owner = Join-Path $root 'owner'
        $child = Join-Path $owner 'modules' 'child'
        $inspection = Join-Path $root 'inspection'
        $first = Join-Path $inspection 'first'
        $download = Join-Path $first 'modules' 'original'
        $second = Join-Path $inspection 'second'
        $null = New-Item -ItemType Directory -Path $owner, $child, $download, $second -Force
        [System.IO.File]::WriteAllText((Join-Path $download 'main.tf'), "variable `"name`" { type = string }`n")
        [System.IO.File]::WriteAllText((Join-Path $download 'locals.tf.json'), '{"locals":{"region":"eastus"}}')
        $record = @{ Key = 'original'; Source = 'registry.terraform.io/Azure/example/azure'; Version = '1.2.3'; Dir = $download }
        [pscustomobject]@{
            Owner = $owner
            Child = $child
            Inspection = $inspection
            First = $first
            Download = $download
            Second = $second
            Cache = [hashtable]::new([StringComparer]::Ordinal)
            Manifest = @{ Modules = @(@{ Key = ''; Source = ''; Dir = '.' }, $record) }
            Targets = @([pscustomobject]@{ Path = $owner }, [pscustomobject]@{ Path = $child })
            Options = [pscustomobject]@{ InspectionRoot = $inspection; ToolPath = 'fixture-mapotf'; EnvVars = @{} }
        }
    }

    function Register-InspectionFixture {
        param($Fixture)
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $Fixture } {
            param($Fixture)
            Register-AvmTerraformInspectionModule -Manifest $Fixture.Manifest -WorkingDirectory $Fixture.Owner `
                -DataDirectory $Fixture.First -InspectionRoot $Fixture.Inspection -Cache $Fixture.Cache
        }
    }

    function Initialize-InspectionFixture {
        param($Fixture, [switch] $WhatIf)
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $Fixture; DryRun = [bool]$WhatIf } {
            param($Fixture, $DryRun)
            Initialize-AvmTerraformInspectionModule -Path $Fixture.Owner -DataDirectory $Fixture.Second `
                -ModuleTargets $Fixture.Targets -Options $Fixture.Options -Cache $Fixture.Cache -WhatIf:$DryRun -Confirm:$false
        }
    }
}

AfterAll { Remove-Module -Name Avm.Authoring -Force }

Describe 'Component: invocation-owned inspection packages' -Tag Component {
    BeforeEach {
        $script:fixture = New-InspectionCacheFixture
        $calls = @{
            $script:fixture.Owner = @{ renamed = @{ source = 'Azure/example/azure'; version = '1.2.3' } }
            $script:fixture.Child = @{}
        }
        InModuleScope Avm.Authoring -Parameters @{ Calls = $calls } {
            param($Calls)
            $script:inspectionFixtureCalls = $Calls
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -cne 'debug' -or $ArgumentList[-1] -cne 'data.module.avm_inspection.result') {
                    throw "Unexpected fixture process: $($ArgumentList -join ' ')"
                }
                [pscustomobject]@{ StdOut = ConvertTo-Json -InputObject $script:inspectionFixtureCalls[$WorkingDirectory] -Depth 10 -Compress }
            }
        }
    }

    It 'copies an exact package under a new call name without source initialization data' {
        Register-InspectionFixture $script:fixture
        $script:fixture.Cache.Count | Should -Be 1
        Initialize-InspectionFixture $script:fixture | Should -Be 1
        $path = Join-Path $script:fixture.Second 'modules' 'modules.json'
        $records = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable).Modules
        $records | Should -HaveCount 2
        $records[0].Key | Should -BeExactly ''
        $records[1].Key | Should -BeExactly 'renamed'
        $records[1].Source | Should -BeExactly 'registry.terraform.io/Azure/example/azure'
        $records[1].Version | Should -BeExactly '1.2.3'
        $copy = Join-Path $script:fixture.Second 'modules' 'renamed'
        [System.IO.Path]::GetFullPath($records[1].Dir) | Should -BeExactly $copy
        foreach ($file in @(Get-ChildItem -LiteralPath $script:fixture.Download -File)) {
            (Get-FileHash -LiteralPath (Join-Path $copy $file.Name)).Hash | Should -BeExactly (Get-FileHash -LiteralPath $file.FullName).Hash
        }
        Test-Path -LiteralPath (Join-Path $script:fixture.Owner '.terraform') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:fixture.Second 'providers') | Should -BeFalse
    }

    It 'builds current local parent records and remaps nested remote calls' {
        Register-InspectionFixture $script:fixture
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
            param($Fixture)
            $script:inspectionFixtureCalls[$Fixture.Owner] = @{ wrapper = @{ source = './modules/child' } }
            $script:inspectionFixtureCalls[$Fixture.Child] = @{ renamed = @{ source = 'Azure/example/azure'; version = '1.2.3' } }
        }
        Initialize-InspectionFixture $script:fixture | Should -Be 1
        $records = (Get-Content -LiteralPath (Join-Path $script:fixture.Second 'modules' 'modules.json') -Raw | ConvertFrom-Json -AsHashtable).Modules
        $records.Key | Should -Be @('', 'wrapper', 'wrapper.renamed')
        [System.IO.Path]::GetFullPath($records[1].Dir) | Should -BeExactly $script:fixture.Child
        $records[1].Source | Should -BeExactly './modules/child'
    }

    It 'does not reuse a changed source or selection: <Case>' -ForEach @(
        @{ Case = 'source'; Source = 'Azure/different/azure'; Version = '1.2.3' }
        @{ Case = 'version'; Source = 'Azure/example/azure'; Version = '1.2.4' }
        @{ Case = 'version constraint'; Source = 'Azure/example/azure'; Version = '~> 1.2' }
        @{ Case = 'Git revision'; Source = 'git::https://github.com/Azure/example?ref=v1'; Version = '' }
    ) {
        Register-InspectionFixture $script:fixture
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture; Source = $Source; Version = $Version } {
            param($Fixture, $Source, $Version)
            $script:inspectionFixtureCalls[$Fixture.Owner] = @{ renamed = @{ source = $Source; version = $Version } }
        }
        Initialize-InspectionFixture $script:fixture | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:fixture.Second 'modules') | Should -BeFalse
    }

    It 'reads current local calls rather than reusing an earlier graph' {
        Register-InspectionFixture $script:fixture
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
            param($Fixture)
            $script:inspectionFixtureCalls[$Fixture.Owner] = @{ wrapper = @{ source = './modules/child' } }
            $script:inspectionFixtureCalls[$Fixture.Child] = @{ renamed = @{ source = 'Azure/example/azure'; version = '1.2.3' } }
        }
        Initialize-InspectionFixture $script:fixture | Should -Be 1
        $script:fixture.Second = Join-Path $script:fixture.Inspection 'third'
        $null = New-Item -ItemType Directory -Path $script:fixture.Second
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
            param($Fixture)
            $script:inspectionFixtureCalls[$Fixture.Child] = @{ renamed = @{ source = 'Azure/example/azure'; version = '1.2.4' } }
        }
        Initialize-InspectionFixture $script:fixture | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:fixture.Second 'modules') | Should -BeFalse
    }

    It 'does not reuse modified or incomplete downloaded content: <Change>' -ForEach @(
        @{ Change = 'edit' }
        @{ Change = 'delete' }
        @{ Change = 'add' }
    ) {
        Register-InspectionFixture $script:fixture
        switch ($Change) {
            'edit' { Set-Content -LiteralPath (Join-Path $script:fixture.Download 'main.tf') -Value 'changed' }
            'delete' { Remove-Item -LiteralPath (Join-Path $script:fixture.Download 'main.tf') }
            'add' { Set-Content -LiteralPath (Join-Path $script:fixture.Download 'new.tf') -Value 'locals {}' }
        }
        { Initialize-InspectionFixture $script:fixture } | Should -Throw '*changed; retry the transform*'
        Test-Path -LiteralPath (Join-Path $script:fixture.Second 'modules') | Should -BeFalse
    }

    It 'never registers local, private, ranged or unexpected package locations: <Case>' -ForEach @(
        @{ Case = 'local'; Source = '../child'; Version = $null }
        @{ Case = 'private'; Source = 'private.example/Azure/example/azure'; Version = '1.2.3' }
        @{ Case = 'subdirectory'; Source = 'Azure/example/azure//nested'; Version = '1.2.3' }
        @{ Case = 'ranged selection'; Source = 'Azure/example/azure'; Version = '~> 1.2' }
        @{ Case = 'source tree'; Source = 'Azure/example/azure'; Version = '1.2.3'; SourceTree = $true }
        @{ Case = 'test-only key'; Source = 'Azure/example/azure'; Version = '1.2.3'; Key = 'test.tests/unit.x' }
    ) {
        param($Source, $Version, $SourceTree = $false, $Key)
        $record = $script:fixture.Manifest.Modules[1]
        $record.Source = $Source
        $record.Version = $Version
        if ($SourceTree) { $record.Dir = $script:fixture.Owner }
        if ($Key) { $record.Key = $Key }
        Register-InspectionFixture $script:fixture
        $script:fixture.Cache.Count | Should -Be 0
    }

    It 'retains distinct source/version packages without folding registry-name case' {
        Register-InspectionFixture $script:fixture
        $script:fixture.Manifest.Modules[1].Version = '1.2.4'
        Register-InspectionFixture $script:fixture
        $script:fixture.Manifest.Modules[1].Source = 'Azure/different/azure'
        Register-InspectionFixture $script:fixture
        $script:fixture.Manifest.Modules[1].Source = 'Azure/Different/azure'
        Register-InspectionFixture $script:fixture
        $script:fixture.Cache.Count | Should -Be 4
    }

    It 'does not cache linked package contents' {
        $linked = Join-Path $script:fixture.Download 'linked'
        $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $kind -Path $linked -Target $script:fixture.Child
        try {
            Register-InspectionFixture $script:fixture
            $script:fixture.Cache.Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $linked -Force }
    }

    It 'does not copy initialization or plan data: <Name>' -ForEach @(
        @{ Name = '.terraform' }
        @{ Name = 'terraform.tfstate' }
        @{ Name = 'terraform.tfstate.backup' }
        @{ Name = 'tfplan' }
        @{ Name = 'tfplan.json' }
    ) {
        [System.IO.File]::WriteAllText((Join-Path $script:fixture.Download $Name), 'not module source')
        Register-InspectionFixture $script:fixture
        $script:fixture.Cache.Count | Should -Be 0
    }

    It 'does not seed an incomplete view of module calls: <Name>' -ForEach @(
        @{ Name = 'override.tf'; Text = 'module "renamed" { version = "~> 2.0" }' }
        @{ Name = 'local_override.tf'; Text = 'module "renamed" { version = "~> 2.0" }' }
        @{ Name = 'override.tf.json'; Text = '{"module":{"renamed":{"version":"~> 2.0"}}}' }
        @{ Name = 'extra.tf.json'; Text = '{"module":{"other":{"source":"Azure/other/azure"}}}' }
    ) {
        Register-InspectionFixture $script:fixture
        [System.IO.File]::WriteAllText((Join-Path $script:fixture.Owner $Name), $Text)
        Initialize-InspectionFixture $script:fixture | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:fixture.Second 'modules') | Should -BeFalse
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'rejects a cache pointer outside the owned inspection root' {
        Register-InspectionFixture $script:fixture
        $script:fixture.Cache.Values | ForEach-Object { $_.Directory = $script:fixture.Owner }
        { Initialize-InspectionFixture $script:fixture } | Should -Throw '*inside the owned temporary inspection directory*'
    }

    It 'requires a fresh data directory and preserves its existing contents' {
        Register-InspectionFixture $script:fixture
        $existing = Join-Path $script:fixture.Second 'preserved.txt'
        [System.IO.File]::WriteAllText($existing, 'unchanged')
        { Initialize-InspectionFixture $script:fixture } | Should -Throw '*fresh, unlinked inspection data directory*'
        [System.IO.File]::ReadAllText($existing) | Should -BeExactly 'unchanged'
    }

    It 'propagates native inspection failure rather than seeding a guessed graph' {
        Register-InspectionFixture $script:fixture
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring { throw [System.InvalidOperationException]::new('native inspection failed') }
        { Initialize-InspectionFixture $script:fixture } | Should -Throw '*native inspection failed*'
        Test-Path -LiteralPath (Join-Path $script:fixture.Second 'modules') | Should -BeFalse
    }

    It 'rejects malformed native inspection: <Payload>' -ForEach @(
        @{ Payload = 'invalid' }
        @{ Payload = '[]' }
        @{ Payload = 'null' }
    ) {
        Register-InspectionFixture $script:fixture
        $script:fixture.Options.EnvVars.Payload = $Payload
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            param($EnvVars)
            [pscustomobject]@{ StdOut = $EnvVars.Payload }
        }
        { Initialize-InspectionFixture $script:fixture } | Should -Throw '*Cannot inspect module calls for dependency reuse*'
    }

    It 'does not modify files or inspect calls under WhatIf' {
        Register-InspectionFixture $script:fixture
        Initialize-InspectionFixture $script:fixture -WhatIf | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:fixture.Inspection 'module-inspection') | Should -BeFalse
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'does not inspect or seed a new invocation with no admitted packages' {
        Initialize-InspectionFixture $script:fixture | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:fixture.Inspection 'module-inspection') | Should -BeFalse
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'leaves unknown and cyclic local graphs for native Terraform installation: <Case>' -ForEach @(
        @{ Case = 'unknown'; Source = './unlisted' }
        @{ Case = 'cycle'; Source = './' }
    ) {
        Register-InspectionFixture $script:fixture
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture; Source = $Source } {
            param($Fixture, $Source)
            $script:inspectionFixtureCalls[$Fixture.Owner] = @{ wrapper = @{ source = $Source } }
        }
        Initialize-InspectionFixture $script:fixture | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:fixture.Second 'modules') | Should -BeFalse
    }

    It 'captures packages only after successful installation, provider inspection and manifest validation: <Failure>' -ForEach @(
        @{ Failure = 'none' }
        @{ Failure = 'get' }
        @{ Failure = 'providers' }
        @{ Failure = 'manifest' }
    ) {
        $script:fixture.Options | Add-Member -NotePropertyName InspectionModuleCache -NotePropertyValue $script:fixture.Cache
        $script:fixture.Options | Add-Member -NotePropertyName TerraformPath -NotePropertyValue 'fixture-terraform'
        $script:fixture.Options.EnvVars.Failure = $Failure
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            param($ArgumentList, $EnvVars)
            if ($ArgumentList[0] -ceq 'get') {
                $directory = Join-Path $EnvVars.TF_DATA_DIR 'modules' 'remote'
                $null = New-Item -ItemType Directory -Path $directory -Force
                [System.IO.File]::WriteAllText((Join-Path $directory 'main.tf'), 'terraform {}')
                $payload = @{
                    Modules = @(
                        @{ Key = ''; Source = ''; Dir = '.' }
                        @{ Key = 'remote'; Source = 'Azure/example/azure'; Version = '1.2.3'; Dir = $directory }
                    )
                } | ConvertTo-Json -Depth 5 -Compress
                if ($EnvVars.Failure -ceq 'manifest') { $payload = 'invalid JSON' }
                [System.IO.File]::WriteAllText((Join-Path $EnvVars.TF_DATA_DIR 'modules' 'modules.json'), $payload)
                if ($EnvVars.Failure -ceq 'get') { throw [System.InvalidOperationException]::new('fixture get failed') }
                return
            }
            if ($ArgumentList[0] -ceq 'providers') {
                if ($EnvVars.Failure -ceq 'providers') { throw [System.InvalidOperationException]::new('fixture providers failed') }
                return [pscustomobject]@{ StdOut = "Providers required by configuration:`n." }
            }
            throw 'Unexpected dependency inspection command.'
        }
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture; Failure = $Failure } {
            param($Fixture, $Failure)
            $inspect = {
                Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Owner -ModuleTargets $Fixture.Targets -Options $Fixture.Options
            }
            if ($Failure -ceq 'none') {
                & $inspect
                $Fixture.Cache.Count | Should -Be 1
            }
            else {
                $expected = if ($Failure -ceq 'manifest') { '*not valid JSON*' } else { "*fixture $Failure failed*" }
                $inspect | Should -Throw $expected
                $Fixture.Cache.Count | Should -Be 0
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -ceq 'get' }
            Should -Invoke Invoke-AvmProcess -Exactly $(if ($Failure -ceq 'get') { 0 } else { 1 }) `
                -ParameterFilter { $ArgumentList[0] -ceq 'providers' }
        }
        Test-Path -LiteralPath (Join-Path $script:fixture.Owner '.terraform') | Should -BeFalse
    }
}
