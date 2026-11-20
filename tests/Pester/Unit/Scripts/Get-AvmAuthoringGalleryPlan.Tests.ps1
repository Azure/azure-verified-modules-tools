Describe 'Get-AvmAuthoringGalleryPlan' {
    BeforeAll {
        $script:planner = Join-Path $PSScriptRoot '../../../../scripts/Get-AvmAuthoringGalleryPlan.ps1'
        function gh { }
    }

    BeforeEach {
        $script:previousOutput = $env:GITHUB_OUTPUT
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'output'
        Remove-Item -LiteralPath $env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
        Mock gh { 'v1.0.0', 'v1.1.0', 'v1.2.0', 'V1.3.0', 'v1.4.0-preview' }
        Mock Invoke-RestMethod {
            @{ name = 'psresource/avm.authoring'; tags = @('1.0.0', '1.1.0', '1.3.0', '1.4.0', '1.5.0') }
        }
        Mock Find-PSResource { [pscustomobject]@{ Version = [version]'1.0.0' } }
    }

    AfterEach {
        $env:GITHUB_OUTPUT = $script:previousOutput
        Remove-Variable -Name AvmAuthoringGalleryFindAttempts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'plans only a full stable release that is in MCR and missing from Gallery' {
        & $script:planner
        Get-Content -LiteralPath $env:GITHUB_OUTPUT | Should -BeExactly 'tags=v1.1.0'
    }

    It 'does not publish an already-published manual selection' {
        & $script:planner -ReleaseTag v1.0.0
        Get-Content -LiteralPath $env:GITHUB_OUTPUT | Should -BeExactly 'tags='
    }

    It 'retries a Gallery package-not-found response' {
        $global:AvmAuthoringGalleryFindAttempts = 0
        Mock Find-PSResource {
            $global:AvmAuthoringGalleryFindAttempts++
            if ($global:AvmAuthoringGalleryFindAttempts -eq 1) {
                Write-Error 'Package does not exist on the server.'
            } else {
                [pscustomobject]@{ Version = [version]'1.0.0' }
            }
        }

        & $script:planner

        Get-Content -LiteralPath $env:GITHUB_OUTPUT | Should -BeExactly 'tags=v1.1.0'
        Should -Invoke Find-PSResource -Exactly 2
    }

    It 'rejects a manual tag that is not ready: <Tag>' -TestCases @(
        @{ Tag = 'v1.2.0'; Message = '*not available in MCR*' }
        @{ Tag = 'v1.5.0'; Message = '*existing published full GitHub release*' }
    ) {
        param($Tag, $Message)
        { & $script:planner -ReleaseTag $Tag } | Should -Throw $Message
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }
}
