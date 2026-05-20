#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Convert-AvmBicepToArm' {
    BeforeEach {
        $script:bicepPath = Join-Path $TestDrive ('main-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.bicep')
        Set-Content -LiteralPath $script:bicepPath -Value "param x string`noutput x string = x" -Encoding utf8
    }

    It 'throws FileNotFoundException when the template does not exist' {
        $missing = Join-Path $TestDrive 'does-not-exist.bicep'
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $missing } {
                param($P)
                Convert-AvmBicepToArm -BicepFilePath $P
            }
        } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
    }

    It 'returns the parsed ARM JSON and the tool identity on success' {
        $p = $script:bicepPath
        $armJson = @{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
            contentVersion = '1.0.0.0'
            parameters     = @{ x = @{ type = 'string' } }
            resources      = @()
            outputs        = @{ x = @{ type = 'string'; value = "[parameters('x')]" } }
        } | ConvertTo-Json -Depth 10

        $r = InModuleScope 'Avm.Authoring' -Parameters @{ P = $p; J = $armJson } {
            param($P, $J)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/bicep'
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $J; StdErr = '' } }
            Convert-AvmBicepToArm -BicepFilePath $P
        }

        $r.ToolName    | Should -Be 'bicep'
        $r.ToolVersion | Should -Be '0.30.3'
        $r.ToolPath    | Should -Be '/fake/bicep'
        $r.ToolSource  | Should -Be 'cache'
        $r.Arm.outputs.x.type | Should -Be 'string'
    }

    It 'throws AvmProcessException when bicep exits non-zero' {
        $p = $script:bicepPath
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
                param($P)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/bicep'
                    }
                }
                Mock Invoke-AvmProcess {
                    [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'BCP018: Expected the "=" character at this location.' }
                }
                Convert-AvmBicepToArm -BicepFilePath $P
            }
        }
        catch {
            $err = $_.Exception
        }

        $err                 | Should -Not -BeNullOrEmpty
        $err.GetType().Name  | Should -Be 'AvmProcessException'
        $err.Message         | Should -Match 'BCP018'
        $err.Message         | Should -Match 'exit'
    }

    It 'throws AvmProcessException when bicep prints nothing on success' {
        $p = $script:bicepPath
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
                param($P)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/bicep'
                    }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                Convert-AvmBicepToArm -BicepFilePath $P
            }
        }
        catch {
            $err = $_.Exception
        }

        $err                 | Should -Not -BeNullOrEmpty
        $err.GetType().Name  | Should -Be 'AvmProcessException'
        $err.Message         | Should -Match 'no output'
    }

    It 'throws AvmProcessException when bicep stdout is not valid JSON' {
        $p = $script:bicepPath
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $p } {
                param($P)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'bicep'; Version = '0.30.3'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/bicep'
                    }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = '{ not json'; StdErr = '' } }
                Convert-AvmBicepToArm -BicepFilePath $P
            }
        }
        catch {
            $err = $_.Exception
        }

        $err                 | Should -Not -BeNullOrEmpty
        $err.GetType().Name  | Should -Be 'AvmProcessException'
        $err.Message         | Should -Match 'not valid JSON'
    }
}
