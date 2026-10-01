#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmAppInstallationMissingConfiguration' {
    It 'returns only the configuration files on main that do not list the repository' {
        $missing = InModuleScope 'Avm.Authoring' {
            $encode = { param($names) @{ content = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(
                            ((@('repositories:') + @($names | ForEach-Object { "  - $_" })) -join "`n"))) } }
            $listed = & $encode @('a-repo', 'Terraform-Azure-AVM-Res-Web-Site')
            $unlisted = & $encode @('a-repo')
            Mock Invoke-AvmGitHubApi -MockWith ({ $listed }.GetNewClosure()) -ParameterFilter {
                $Endpoint -eq 'repos/microsoft/github-operations/contents/apps/azure/azure-verified-modules.yaml?ref=main'
            }
            Mock Invoke-AvmGitHubApi -MockWith ({ $unlisted }.GetNewClosure()) -ParameterFilter {
                $Endpoint -eq 'repos/microsoft/github-operations/contents/apps/azure/terraform-cloud.yaml?ref=main'
            }
            Mock Invoke-AvmGitHubApi { throw "Unexpected call: $Endpoint" }
            Get-AvmAppInstallationMissingConfiguration -Repository 'terraform-azure-avm-res-web-site'
        }

        @($missing) | Should -Be @('apps/azure/terraform-cloud.yaml')
    }

    It 'checks only the requested configuration files' {
        $missing = InModuleScope 'Avm.Authoring' {
            $content = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("repositories:`n  - other`n"))
            Mock Invoke-AvmGitHubApi -MockWith ({ @{ content = $content } }.GetNewClosure())
            Get-AvmAppInstallationMissingConfiguration -Repository 'terraform-azure-avm-res-web-site' `
                -ConfigurationPath 'apps/azure/azure-verified-modules.yaml'
            Should -Invoke Invoke-AvmGitHubApi -Exactly 1
        }

        @($missing) | Should -Be @('apps/azure/azure-verified-modules.yaml')
    }
}
