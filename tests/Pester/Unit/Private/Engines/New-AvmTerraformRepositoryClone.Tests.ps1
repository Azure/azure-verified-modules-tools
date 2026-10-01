#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'New-AvmTerraformRepositoryClone' {
    BeforeEach {
        $parent = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $parent
        $path = Join-Path $parent 'terraform-azure-avm-res-test'
        $fake = @{
            Origin    = 'https://github.com/Azure/terraform-azure-avm-res-test.git'
            HasHead   = $true
            Published = "{`n  `"moduleDisplayName`": `"Test`"`n}`n"
            Clone     = $true
            OnClone   = $null
        }
        Mock -ModuleName Avm.Authoring Invoke-AvmGit -MockWith ({
                param([string[]] $ArgumentList)
                switch -Exact ($ArgumentList[0]) {
                    'config' {
                        return [pscustomobject]@{ ExitCode = 0; StdOut = "$($fake.Origin)`n"; StdErr = '' }
                    }
                    'rev-parse' {
                        return [pscustomobject]@{ ExitCode = if ($fake.HasHead) { 0 } else { 1 }; StdOut = ''; StdErr = '' }
                    }
                    'show' {
                        return [pscustomobject]@{ ExitCode = 0; StdOut = $fake.Published; StdErr = '' }
                    }
                    'clone' {
                        $destination = $ArgumentList[-1]
                        if ($fake.Clone) {
                            $null = New-Item -ItemType Directory -Path (Join-Path $destination '.git') -Force
                            [System.IO.File]::WriteAllText((Join-Path $destination 'metadata.json'), $fake.Published)
                            [System.IO.File]::WriteAllText((Join-Path $destination 'terraform.tf'), "terraform {}`n")
                        }
                        if ($fake.OnClone) {
                            & $fake.OnClone
                        }
                        return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                    }
                }
                throw "Unexpected git call: $($ArgumentList -join ' ')"
            }.GetNewClosure())
        $clone = {
            param([switch] $Plan)
            InModuleScope 'Avm.Authoring' -Parameters @{ Path = $path; Plan = [bool]$Plan } {
                param($Path, $Plan)
                New-AvmTerraformRepositoryClone -Path $Path -Repository 'Azure/terraform-azure-avm-res-test' -Confirm:$false -WhatIf:$Plan
            }
        }
    }

    It 'keeps an existing clone whose origin is <Origin>' -TestCases @(
        @{ Origin = 'https://github.com/Azure/terraform-azure-avm-res-test.git' }
        @{ Origin = 'https://github.com/Azure/terraform-azure-avm-res-test/' }
        @{ Origin = 'git@github.com:Azure/terraform-azure-avm-res-test.git' }
    ) {
        param($Origin)
        $fake.Origin = $Origin
        $null = New-Item -ItemType Directory -Path (Join-Path $path '.git') -Force

        $result = & $clone

        $result.Status | Should -Be 'pass'
        $result.Detail | Should -Be "existing clone at $path"
        Should -Invoke Invoke-AvmGit -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter { $ArgumentList[0] -eq 'clone' }
    }

    It 'skips an existing clone of <Case>' -TestCases @(
        @{
            Case    = 'another repository'
            Origin  = 'https://github.com/Azure/other.git'
            HasHead = $true
            Detail  = '* is not a clone of https://github.com/Azure/terraform-azure-avm-res-test'
        }
        @{
            Case    = 'the repository without commits'
            Origin  = 'https://github.com/Azure/terraform-azure-avm-res-test.git'
            HasHead = $false
            Detail  = '* has no commits yet; pull main into it'
        }
    ) {
        param($Case, $Origin, $HasHead, $Detail)
        $fake.Origin = $Origin
        $fake.HasHead = $HasHead
        $null = New-Item -ItemType Directory -Path (Join-Path $path '.git') -Force

        $result = & $clone

        $result.Status | Should -Be 'skipped'
        $result.Detail | Should -BeLike $Detail
        Should -Invoke Invoke-AvmGit -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter { $ArgumentList[0] -eq 'clone' }
    }

    It 'leaves a folder holding <Files> untouched' -TestCases @(
        @{ Files = @('main.tf') }
        @{ Files = @('metadata.json', 'notes.md') }
    ) {
        param($Files)
        $null = New-Item -ItemType Directory -Path $path
        foreach ($file in $Files) {
            [System.IO.File]::WriteAllText((Join-Path $path $file), "local`n")
        }

        $result = & $clone

        $result.Status | Should -Be 'skipped'
        $result.Detail | Should -BeLike '* holds other files; clone https://github.com/Azure/terraform-azure-avm-res-test to start work'
        @(Get-ChildItem -LiteralPath $path -Force | Sort-Object Name).Name | Should -Be @($Files | Sort-Object)
        Should -Invoke Invoke-AvmGit -ModuleName Avm.Authoring -Exactly 0
    }

    It 'clones into <Case>' -TestCases @(
        @{ Case = 'a missing folder'; Create = $false; Metadata = $false }
        @{ Case = 'an empty folder'; Create = $true; Metadata = $false }
        @{ Case = 'a folder holding only the published metadata.json'; Create = $true; Metadata = $true }
    ) {
        param($Case, $Create, $Metadata)
        if ($Create) {
            $null = New-Item -ItemType Directory -Path $path
        }
        if ($Metadata) {
            [System.IO.File]::WriteAllText((Join-Path $path 'metadata.json'), $fake.Published)
        }

        $result = & $clone

        $result.Status | Should -Be 'pass'
        $result.Detail | Should -Be "cloned to $path"
        @(Get-ChildItem -LiteralPath $path -Force | Sort-Object Name).Name | Should -Be @('.git', 'metadata.json', 'terraform.tf')
        @(Get-ChildItem -LiteralPath $parent -Force).Name | Should -Be @('terraform-azure-avm-res-test')
        Should -Invoke Invoke-AvmGit -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $ArgumentList[0] -eq 'clone' -and $ArgumentList[2] -eq 'https://github.com/Azure/terraform-azure-avm-res-test.git' -and
            $UseGitHubCredential
        }
    }

    It 'keeps a metadata.json that differs from main' {
        $null = New-Item -ItemType Directory -Path $path
        [System.IO.File]::WriteAllText((Join-Path $path 'metadata.json'), "{}`n")

        $result = & $clone

        $result.Status | Should -Be 'skipped'
        $result.Detail | Should -BeLike '* holds a metadata.json that differs from main; clone *'
        [System.IO.File]::ReadAllText((Join-Path $path 'metadata.json')) | Should -BeExactly "{}`n"
        @(Get-ChildItem -LiteralPath $parent -Force).Name | Should -Be @('terraform-azure-avm-res-test')
    }

    It 'leaves the folder untouched when files appear in it during the clone' {
        $null = New-Item -ItemType Directory -Path $path
        $fake.OnClone = { [System.IO.File]::WriteAllText((Join-Path $path 'main.tf'), "# new work`n") }.GetNewClosure()

        $result = & $clone

        $result.Status | Should -Be 'skipped'
        $result.Detail | Should -BeLike '* holds other files; *'
        @(Get-ChildItem -LiteralPath $path -Force).Name | Should -Be @('main.tf')
        @(Get-ChildItem -LiteralPath $parent -Force).Name | Should -Be @('terraform-azure-avm-res-test')
    }

    It 'puts metadata.json back when the clone cannot be moved into place' {
        $null = New-Item -ItemType Directory -Path $path
        [System.IO.File]::WriteAllText((Join-Path $path 'metadata.json'), $fake.Published)
        $fake.Clone = $false

        { & $clone } | Should -Throw

        @(Get-ChildItem -LiteralPath $path -Force).Name | Should -Be @('metadata.json')
        [System.IO.File]::ReadAllText((Join-Path $path 'metadata.json')) | Should -BeExactly $fake.Published
        @(Get-ChildItem -LiteralPath $parent -Force).Name | Should -Be @('terraform-azure-avm-res-test')
    }

    It 'removes a partial clone and leaves the folder untouched when cloning fails' {
        $null = New-Item -ItemType Directory -Path $path
        [System.IO.File]::WriteAllText((Join-Path $path 'metadata.json'), $fake.Published)
        $fake.OnClone = { throw 'fatal: could not read from remote repository' }

        { & $clone } | Should -Throw '*could not read from remote repository*'

        @(Get-ChildItem -LiteralPath $path -Force).Name | Should -Be @('metadata.json')
        @(Get-ChildItem -LiteralPath $parent -Force).Name | Should -Be @('terraform-azure-avm-res-test')
    }

    It 'plans the clone under WhatIf without touching the folder' {
        $result = & $clone -Plan

        $result.Status | Should -Be 'planned'
        $result.Detail | Should -Be "clone to $path"
        Test-Path -LiteralPath $path | Should -BeFalse
        Should -Invoke Invoke-AvmGit -ModuleName Avm.Authoring -Exactly 0
    }
}
