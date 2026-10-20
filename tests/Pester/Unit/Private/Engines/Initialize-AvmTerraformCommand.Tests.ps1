#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Initialize-AvmTerraformCommand' {
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            $script:initializeContext = [pscustomobject]@{
                Kind = 'terraform-module-repo'
                Root = Join-Path $TestDrive 'module'
                Ecosystem = 'terraform'
            }
            Mock Get-AvmTerraformPluginCachePath { Join-Path $TestDrive 'provider-cache' }
            Mock Get-AvmFolder { Join-Path $TestDrive 'cache' }
            Mock New-Item {}
            Mock Write-AvmLog {}
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'terraform'; Version = '1.16.5'; Path = 'terraform-stub'; Source = 'cache'
                }
            }
            Mock Invoke-AvmTerraformInit {
                [pscustomobject]@{ ExitCode = 0 }
            }
        }
    }

    It 'prepares shared caches without initializing unused source directories for pre-commit' {
        InModuleScope 'Avm.Authoring' {
            $result = Initialize-AvmTerraformCommand `
                -Context $script:initializeContext `
                -Command pre-commit

            $result.Status | Should -Be 'pass'
            $result.InitializedDirectories | Should -Be 0
            $result.ReusedDirectories | Should -Be 0
            Should -Invoke Resolve-AvmTool -Exactly 0
            Should -Invoke Invoke-AvmTerraformInit -Exactly 0
        }
    }

    It 'preserves dependency selections when initializing missing pr-check examples and reuses prepared caches' {
        InModuleScope 'Avm.Authoring' {
            $first = Join-Path $script:initializeContext.Root 'examples' 'first'
            $second = Join-Path $script:initializeContext.Root 'examples' 'second'
            Mock Get-AvmTerraformValidationScope {
                [pscustomobject]@{
                    Examples = @(
                        [pscustomobject]@{
                            Path = $first; RelativePath = 'examples/first'; Files = @(); TestFiles = @()
                        }
                        [pscustomobject]@{
                            Path = $second; RelativePath = 'examples/second'; Files = @(); TestFiles = @()
                        }
                    )
                    Modules = @()
                }
            }
            Mock Test-Path {
                $LiteralPath -like '*examples\first\.terraform*' -or
                $LiteralPath -like '*/examples/first/.terraform*'
            }

            $result = Initialize-AvmTerraformCommand `
                -Context $script:initializeContext `
                -Command pr-check `
                -AllowPathFallback

            $result.Status | Should -Be 'pass'
            $result.Initialized | Should -Be @('examples/second')
            $result.Reused | Should -Be @('examples/first')
            Should -Invoke Invoke-AvmTerraformInit -Exactly 1 -ParameterFilter {
                $WorkingDirectory -eq $second -and
                $BackendFalse -and
                $NoColor -and
                $PreserveDependencySelections -and
                $EnvVars.TF_PLUGIN_CACHE_DIR -eq (Join-Path $TestDrive 'provider-cache')
            }
        }
    }

    It 'propagates incompatible locked dependency failures without retrying with upgrades' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmTerraformValidationScope {
                [pscustomobject]@{
                    Examples = @(
                        [pscustomobject]@{
                            Path = Join-Path $script:initializeContext.Root 'examples' 'default'
                            RelativePath = 'examples/default'
                        }
                    )
                    Modules = @()
                }
            }
            Mock Test-Path { $false }
            $script:initializationFailure = [System.InvalidOperationException]::new('Incompatible locked dependency.')
            Mock Invoke-AvmTerraformInit { throw $script:initializationFailure }

            $failure = $null
            try {
                $null = Initialize-AvmTerraformCommand -Context $script:initializeContext -Command pr-check
            }
            catch {
                $failure = $_.Exception
            }

            $failure | Should -Be $script:initializationFailure
            Should -Invoke Invoke-AvmTerraformInit -Exactly 1
            Should -Invoke Invoke-AvmTerraformInit -Exactly 0 -ParameterFilter {
                -not $PreserveDependencySelections
            }
        }
    }
}
