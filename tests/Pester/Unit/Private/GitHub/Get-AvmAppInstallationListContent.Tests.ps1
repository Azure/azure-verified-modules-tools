#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:yaml = @(
        'expected_permissions: contents=read'
        'repository_selection: selected'
        'repositories:'
        '  - avm-container-images'
        '  - Azure-Verified-Modules'
        '  - terraform-azure-avm-res-app-agent'
        '  - terraform-azure-avm-res-web-site'
        'trailing_key: value'
        ''
    ) -join "`n"
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmAppInstallationListContent' {
    It 'inserts the repository in case-insensitive order and keeps every other line' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Yaml = $script:yaml } {
            param($Yaml)
            Get-AvmAppInstallationListContent -Content $Yaml -Repository 'terraform-azure-avm-res-signalrservice-webpubsub'
        }

        $result.Changed | Should -BeTrue
        $result.Listed | Should -BeFalse
        $result.Content | Should -BeExactly ($script:yaml.Replace(
                "  - terraform-azure-avm-res-web-site`n",
                "  - terraform-azure-avm-res-signalrservice-webpubsub`n  - terraform-azure-avm-res-web-site`n"))
    }

    It 'appends after the last item without moving later keys' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Yaml = $script:yaml } {
            param($Yaml)
            Get-AvmAppInstallationListContent -Content $Yaml -Repository 'tflint-ruleset-avm'
        }

        $result.Content | Should -BeExactly ($script:yaml.Replace(
                "  - terraform-azure-avm-res-web-site`ntrailing_key",
                "  - terraform-azure-avm-res-web-site`n  - tflint-ruleset-avm`ntrailing_key"))
    }

    It 'reports an existing entry regardless of case without changing content' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Yaml = $script:yaml } {
            param($Yaml)
            Get-AvmAppInstallationListContent -Content $Yaml -Repository 'azure-verified-modules'
        }

        $result.Listed | Should -BeTrue
        $result.Changed | Should -BeFalse
        $result.Content | Should -BeExactly $script:yaml
    }

    It 'preserves CRLF line endings' {
        $result = InModuleScope 'Avm.Authoring' {
            Get-AvmAppInstallationListContent -Content "repositories:`r`n  - b-repo`r`n" -Repository 'a-repo'
        }
        $result.Content | Should -BeExactly "repositories:`r`n  - a-repo`r`n  - b-repo`r`n"
    }

    It 'adds the first entry to an empty list with the default indent' {
        $result = InModuleScope 'Avm.Authoring' {
            Get-AvmAppInstallationListContent -Content "repositories:`nrepository_selection: selected`n" -Repository 'a-repo'
        }
        $result.Content | Should -BeExactly "repositories:`n  - a-repo`nrepository_selection: selected`n"
    }

    It 'rejects content without exactly one top-level repositories list' -TestCases @(
        @{ Content = "repository_selection: selected`n" }
        @{ Content = "repositories:`n  - a`nrepositories:`n  - b`n" }
        @{ Content = "repositories: []`n" }
    ) {
        param($Content)
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ Content = $Content } {
                param($Content)
                Get-AvmAppInstallationListContent -Content $Content -Repository 'a-repo'
            }
        } | Should -Throw '*exactly one top-level repositories list*'
    }
}
