#Requires -Version 7.4

Describe 'Integration: Terraform invocation-owned module reuse' -Tag Integration -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
        Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $root = Join-Path $TestDrive 'inspection reuse with spaces'
        $script:first = Join-Path $root 'first'
        $script:second = Join-Path $root 'second'
        $script:child = Join-Path $script:second 'child'
        $null = New-Item -ItemType Directory -Path $script:first, $script:second, $script:child -Force
        $script:source = @'
module "shared" {
  source = "Azure/naming/azurerm"
  version = "0.4.2"
}
'@
        [System.IO.File]::WriteAllText((Join-Path $script:first 'main.tf'), $script:source)
        $script:targets = @(
            [pscustomobject]@{ Path = $script:first }
            [pscustomobject]@{ Path = $script:second }
            [pscustomobject]@{ Path = $script:child }
        )
        $script:options = InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            [pscustomobject]@{
                TerraformPath = (Resolve-AvmTool -Name terraform).Path
                ToolPath = (Resolve-AvmTool -Name mapotf).Path
                EnvVars = @{}
                InspectionRoot = Join-Path $Root 'inspection'
                InspectionModuleCache = [hashtable]::new([StringComparer]::Ordinal)
            }
        }
        InModuleScope Avm.Authoring {
            $script:reuseOriginalProcess = (Get-Command Invoke-AvmProcess).ScriptBlock
        }
        $script:initial = InModuleScope Avm.Authoring -Parameters @{
            Path = $script:first; Targets = $script:targets; Options = $script:options
        } {
            param($Path, $Targets, $Options)
            $manifests = @{}
            $sources = @(Get-AvmTerraformUnitTestProviderSource -Path $Path -ModuleTargets $Targets `
                    -Options $Options -ModuleManifests $manifests)
            @{ Sources = $sources; Manifest = $manifests[$Path] }
        }
        $script:options.InspectionModuleCache.Count | Should -BeGreaterThan 0
    }

    AfterAll {
        Remove-Module -Name Avm.Authoring -Force
    }

    It 'revalidates a fresh native graph without downloading the same exact package: <Nested>' -ForEach @(
        @{ Nested = $false }
        @{ Nested = $true }
    ) {
        param($Nested)
        $path = if ($Nested) { $script:child } else { $script:second }
        if ($Nested) {
            [System.IO.File]::WriteAllText((Join-Path $script:second 'main.tf'), 'module "wrapper" { source = "./child" }')
        }
        [System.IO.File]::WriteAllText((Join-Path $path 'main.tf'), $script:source.Replace('"shared"', '"renamed"'))
        $before = @{}
        foreach ($file in Get-ChildItem -LiteralPath $script:second -Recurse -File) {
            $before[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash
        }
        $observed = InModuleScope Avm.Authoring -Parameters @{
            Path = $script:second; Targets = $script:targets; Options = $script:options
        } {
            param($Path, $Targets, $Options)
            $script:reuseGetOutput = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-AvmProcess {
                $result = & $script:reuseOriginalProcess @PesterBoundParameters
                if ($ArgumentList[0] -ceq 'get' -and -not $RetryNetworkFailure) { $script:reuseGetOutput.Add($result.StdOut) }
                $result
            }
            $manifests = @{}
            $sources = @(Get-AvmTerraformUnitTestProviderSource -Path $Path -ModuleTargets $Targets `
                    -Options $Options -ModuleManifests $manifests)
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList -join '|' -ceq 'get|-no-color' -and [bool]$RetryNetworkFailure
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -ceq 'providers' }
            @{ Sources = $sources; Manifest = $manifests[$Path]; Output = $script:reuseGetOutput.ToArray() -join "`n" }
        }
        $observed.Sources | Sort-Object | Should -Be @($script:initial.Sources | Sort-Object)
        $observed.Output | Should -Not -Match 'Downloading'
        $records = ($observed.Manifest | ConvertFrom-Json -AsHashtable).Modules
        $key = if ($Nested) { 'wrapper.renamed' } else { 'renamed' }
        @($records | Where-Object Key -ceq $key) | Should -HaveCount 1
        @($records | Where-Object Key -ceq 'shared') | Should -HaveCount 0
        foreach ($file in $before.Keys) {
            (Get-FileHash -LiteralPath $file).Hash | Should -BeExactly $before[$file]
        }
        Test-Path -LiteralPath (Join-Path $script:second '.terraform') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:second '.terraform.lock.hcl') | Should -BeFalse
    }

    It 'does not reuse an exact package for a newly authored version constraint' {
        [System.IO.File]::WriteAllText((Join-Path $script:second 'main.tf'), $script:source.Replace('"0.4.2"', '"= 0.4.2"'))
        $output = InModuleScope Avm.Authoring -Parameters @{
            Path = $script:second; Targets = $script:targets; Options = $script:options
        } {
            param($Path, $Targets, $Options)
            $script:reuseGetOutput = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-AvmProcess {
                $result = & $script:reuseOriginalProcess @PesterBoundParameters
                if ($ArgumentList[0] -ceq 'get' -and -not $RetryNetworkFailure) { $script:reuseGetOutput.Add($result.StdOut) }
                $result
            }
            $null = Get-AvmTerraformUnitTestProviderSource -Path $Path -ModuleTargets $Targets -Options $Options
            $script:reuseGetOutput.ToArray() -join "`n"
        }
        $output | Should -Match 'Downloading.*0\.4\.2'
    }

    It 'does not seed base-file selections when Terraform overrides change them' {
        [System.IO.File]::WriteAllText((Join-Path $script:second 'main.tf'), $script:source)
        $overridePath = Join-Path $script:second 'override.tf'
        [System.IO.File]::WriteAllText($overridePath, 'module "shared" { version = "= 0.4.2" }')
        try {
            $output = InModuleScope Avm.Authoring -Parameters @{
                Path = $script:second; Targets = $script:targets; Options = $script:options
            } {
                param($Path, $Targets, $Options)
                $script:reuseGetOutput = [System.Collections.Generic.List[string]]::new()
                Mock Invoke-AvmProcess {
                    $result = & $script:reuseOriginalProcess @PesterBoundParameters
                    if ($ArgumentList[0] -ceq 'get' -and -not $RetryNetworkFailure) { $script:reuseGetOutput.Add($result.StdOut) }
                    $result
                }
                $null = Get-AvmTerraformUnitTestProviderSource -Path $Path -ModuleTargets $Targets -Options $Options
                $script:reuseGetOutput.ToArray() -join "`n"
            }
            $output | Should -Match 'Downloading.*0\.4\.2'
        }
        finally { Remove-Item -LiteralPath $overridePath }
    }
}
