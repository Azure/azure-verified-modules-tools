#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:repoRoot 'tests' 'helpers' 'Install-AvmStubLauncher.ps1')

    $script:savedEnvironment = @{}
    foreach ($name in @('PATH', 'AVM_HOME', 'TF_DATA_DIR', 'AVM_STUB_TERRAFORM_TRACE')) {
        $script:savedEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name)
    }
    $launchers = Install-AvmStubLauncher `
        -StubDir (Join-Path $script:repoRoot 'tests' 'fixtures' 'bin') `
        -LauncherDir (Join-Path $TestDrive 'bin') `
        -PinsPath (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Resources' 'avm.pins.jsonc')
    $env:PATH = $launchers + [System.IO.Path]::PathSeparator + $env:PATH
    $env:TF_DATA_DIR = $null

    function Set-ValidationFixtureFile {
        param(
            [string] $Root,
            [string] $RelativePath,
            [string] $Content
        )

        $path = Join-Path $Root ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        Set-Content -LiteralPath $path -Value $Content -Encoding utf8NoBOM -NoNewline
    }
}

AfterAll {
    foreach ($name in $script:savedEnvironment.Keys) {
        [System.Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
    }
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Terraform example validation and module coverage' -Tag 'Component' {
    BeforeEach {
        $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:fixtureRoot = Join-Path $TestDrive ('module-' + $id)
        $env:AVM_HOME = Join-Path $TestDrive ('avm-home-' + $id)
        $env:AVM_STUB_TERRAFORM_TRACE = Join-Path $TestDrive ('trace-' + $id + '.jsonl')
        $script:manifest = @'
{"Modules":[
  {"Key":"","Source":"","Dir":"."},
  {"Key":"subject","Source":"../..","Dir":"../.."},
  {"Key":"subject.nested","Source":"./modules/nested","Dir":"../../modules/nested"}
]}
'@
        Set-ValidationFixtureFile $script:fixtureRoot 'terraform.tf' "terraform {`n  required_version = `">= 1.15`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'main.tf' "module `"nested`" {`n  source = `"./modules/nested`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'variables.tf' "variable `"legacy`" {`n  type = string`n  default = `"fixture`"`n  deprecated = `"Use current instead.`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'outputs.tf' "output `"legacy`" {`n  value = var.legacy`n  deprecated = `"Use current instead.`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'modules/nested/main.tf' "output `"value`" {`n  value = `"nested`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/default/main.tf' "module `"subject`" {`n  source = `"../..`"`n  legacy = `"fixture`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/default/terraform.tf' "terraform {`n  required_version = `">= 1.15`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/default/.avm-stub-modules.json' $script:manifest
        Set-ValidationFixtureFile $script:fixtureRoot '.avm-stub-validation.json' '{"valid":false,"diagnostics":[{"severity":"error","summary":"The library root must not be validated directly."}]}'
    }

    It 'validates every direct example including e2e-ignored examples and removes isolated data' {
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/ignored/main.tf' "module `"subject`" {`n  source = `"../..`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/ignored/.e2eignore' ''
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/ignored/.avm-stub-modules.json' $script:manifest

        $result = Invoke-AvmTest -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback
        $result.Status | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 3
        $result.Issues | Should -BeNullOrEmpty

        $trace = @(Get-Content -LiteralPath $env:AVM_STUB_TERRAFORM_TRACE | ConvertFrom-Json)
        $validations = @($trace | Where-Object Command -eq 'validate')
        $validations.Count | Should -Be 2
        $validations.Directory | Should -Contain (Join-Path $script:fixtureRoot 'examples' 'default')
        $validations.Directory | Should -Contain (Join-Path $script:fixtureRoot 'examples' 'ignored')
        $validations.Directory | Should -Not -Contain $script:fixtureRoot
        @($validations.DataDirectory | Select-Object -Unique).Count | Should -Be 2
        foreach ($validation in $validations) {
            Test-Path -LiteralPath $validation.DataDirectory | Should -BeFalse
            @($trace | Where-Object {
                    $_.Command -eq 'init' -and $_.Directory -eq $validation.Directory -and
                    $_.DataDirectory -eq $validation.DataDirectory
                }).Count | Should -Be 1
        }
    }

    It 'warns about uncovered modules without trusting a stale caller manifest' {
        Set-ValidationFixtureFile $script:fixtureRoot 'modules/uncovered/main.tf' "output `"value`" {`n  value = `"uncovered`"`n}`n"
        $staleManifest = '{"Modules":[{"Key":"","Dir":"."},{"Key":"old","Dir":"../../modules/uncovered"}]}'
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/default/.terraform/modules/modules.json' $staleManifest
        $stalePath = Join-Path $script:fixtureRoot 'examples' 'default' '.terraform' 'modules' 'modules.json'

        $result = Invoke-AvmTest -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback
        $result.Status | Should -Be 'pass'
        $result.Issues.Count | Should -Be 1
        $result.Issues[0].Code | Should -Be 'terraform.module-coverage'
        $result.Issues[0].Severity | Should -Be 'warning'
        $result.Issues[0].File | Should -Be 'modules/uncovered/main.tf'
        Get-Content -LiteralPath $stalePath -Raw | Should -BeExactly $staleManifest
    }

    It 'discovers JSON configurations but not artifacts, empty directories, or nested examples' {
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/json/main.tf.json' '{"module":{"subject":{"source":"../.."}}}'
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/json/.avm-stub-modules.json' $script:manifest
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/empty/README.md' 'Not a configuration.'
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/outer/inner/main.tf' 'output "value" { value = "nested" }'
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/.terraform/main.tf' 'not Terraform'
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/node_modules/main.tf' 'not Terraform'
        Set-ValidationFixtureFile $script:fixtureRoot 'modules/.terraform/main.tf' 'not Terraform'
        Set-ValidationFixtureFile $script:fixtureRoot 'modules/empty/README.md' 'Not a configuration.'
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/default/.ignored.tf' 'not Terraform'

        $scope = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $script:fixtureRoot } {
            param($Root)
            Get-AvmTerraformValidationScope -Root $Root
        }
        @($scope.Examples.RelativePath) | Should -Be @('examples/default', 'examples/json')
        @($scope.Modules.RelativePath) | Should -Be @('.', 'modules/nested')

        $result = Invoke-AvmTest -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback
        $result.Status | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 3
        $result.Issues | Should -BeNullOrEmpty
    }

    It 'reports real validation errors with repository-relative locations' {
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/default/.avm-stub-validation.json' @'
{"valid":false,"diagnostics":[{
  "severity":"error","summary":"Reference to undeclared local value",
  "range":{"filename":"../../outputs.tf","start":{"line":2,"column":11}}
}]}
'@
        $result = Invoke-AvmTest -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback
        $result.Status | Should -Be 'fail'
        $diagnostic = @($result.Issues | Where-Object Severity -eq 'error')
        $diagnostic.Count | Should -Be 1
        $diagnostic[0].File | Should -Be 'outputs.tf'
        $diagnostic[0].Line | Should -Be 2
        $diagnostic[0].Column | Should -Be 11
        $trace = @(Get-Content -LiteralPath $env:AVM_STUB_TERRAFORM_TRACE | ConvertFrom-Json)
        foreach ($entry in @($trace | Where-Object Command -eq 'validate')) {
            Test-Path -LiteralPath $entry.DataDirectory | Should -BeFalse
        }
    }

    It 'excludes test-only references whose synthetic parents match real module names' {
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/default/main.tf' "module `"test`" {`n  source = `"../../modules/nested`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'modules/nested/main.tf' "module `"nested`" {`n  source = `"../inner`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'modules/inner/main.tf' "output `"value`" {`n  value = `"inner`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/default/setup/main.tf' "module `"subject`" {`n  source = `"../../..`"`n}`n"
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/default/nested.tftest.hcl' @'
run "fixture" {
  command = plan

  module {
    source = "./setup"
  }
}
'@
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/default/.avm-stub-modules.json' @'
{"Modules":[
  {"Key":"","Dir":"."},
  {"Key":"test","Dir":"../../modules/nested"},
  {"Key":"test.nested","Dir":"../../modules/inner"},
  {"Key":"test.nested.fixture","Dir":"setup"},
  {"Key":"test.nested.fixture.subject","Dir":"../.."},
  {"Key":"test.nested.fixture.subject.nested","Dir":"../../modules/nested"},
  {"Key":"test.nested.fixture.subject.nested.nested","Dir":"../../modules/inner"}
]}
'@
        $result = Invoke-AvmTest -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback
        $result.Status | Should -Be 'pass'
        $result.Issues.Count | Should -Be 1
        $result.Issues[0].Code | Should -Be 'terraform.module-coverage'
        $result.Issues[0].Message | Should -Match "module '\.'"
    }

    It 'keeps malformed coverage metadata non-blocking' {
        Set-ValidationFixtureFile $script:fixtureRoot 'examples/default/.avm-stub-modules.json' '{'
        $result = Invoke-AvmTest -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback
        $result.Status | Should -Be 'pass'
        @($result.Issues | Where-Object Code -eq 'terraform.module-coverage-unavailable').Count | Should -Be 1
        @($result.Issues | Where-Object Severity -eq 'error').Count | Should -Be 0
    }

    It 'does not initialize or claim fresh coverage when NoInit is requested' {
        $result = Invoke-AvmTest -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback -NoInit
        $result.Status | Should -Be 'pass'
        $result.Issues.Count | Should -Be 1
        $result.Issues[0].Code | Should -Be 'terraform.module-coverage-unavailable'
        $trace = @(Get-Content -LiteralPath $env:AVM_STUB_TERRAFORM_TRACE | ConvertFrom-Json)
        @($trace | Where-Object Command -eq 'init').Count | Should -Be 0
        @($trace | Where-Object Command -eq 'validate').Count | Should -Be 1
    }

    It 'reports skipped with coverage warnings when no examples exist' {
        Remove-Item -LiteralPath (Join-Path $script:fixtureRoot 'examples') -Recurse -Force
        $result = Invoke-AvmTest -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback
        $result.Status | Should -Be 'skipped'
        $result.FilesProcessed | Should -Be 0
        @($result.Issues | Where-Object Severity -eq 'warning').Count | Should -Be 3
        $trace = @(Get-Content -LiteralPath $env:AVM_STUB_TERRAFORM_TRACE | ConvertFrom-Json)
        @($trace | Where-Object Command -in @('init', 'validate')).Count | Should -Be 0
    }
}
