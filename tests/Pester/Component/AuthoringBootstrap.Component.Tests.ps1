#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
    $workflow = ConvertFrom-Yaml (Get-Content -Raw (Join-Path $script:root '.github' 'workflows' 'authoring-bootstrap.yml'))
    $script:resolve = ($workflow.jobs.bootstrap.steps | Where-Object name -EQ 'Resolve repository commit').with.script
    $script:prepare = [scriptblock]::Create(($workflow.jobs.bootstrap.steps | Where-Object name -EQ 'Prepare module').run)
    $script:module = Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru
    $script:node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $script:harness = @'
const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
const fixture = JSON.parse(process.env.AVM_FIXTURE);
const script = Buffer.from(process.env.AVM_SCRIPT, 'base64').toString('utf8');
const calls = [];
const github = {
  paginate: async () => { calls.push('tags'); return fixture.tags || []; },
  rest: { repos: {
    listTags: async () => {},
    getCommit: async ({ref}) => {
      calls.push(ref);
      if (!fixture.commits[ref]) throw new Error('unresolved ref');
      return {data: {sha: fixture.commits[ref]}};
    }
  }}
};
const outputs = {};
const core = {info: () => {}, setOutput: (name, value) => { outputs[name] = value; }};
new AsyncFunction('github', 'core', script)(github, core)
  .then(() => process.stdout.write(JSON.stringify({outputs, calls})))
  .catch(error => { process.stderr.write(error.message); process.exitCode = 1; });
'@
    function Invoke-RepositorySelectionFixture {
        param([string] $Ref, [hashtable] $Fixture)
        $environment = @{
            AUTHORING_REF = $Ref
            AVM_FIXTURE = ConvertTo-Json -InputObject $Fixture -Depth 20 -Compress
            AVM_SCRIPT = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:resolve))
        }
        & $script:module {
            param($Node, $Harness, $Environment)
            Invoke-AvmProcess -FilePath $Node -ArgumentList @('-e', $Harness) -EnvVars $Environment -IgnoreExitCode
        } $script:node $script:harness $environment
    }
}

Describe 'Repository authoring ref resolution' -Tag 'Component' {
    BeforeAll {
        $script:sha = 'faf10e96bc16002170addd1bcfe91b78bb897c02'
        $script:otherSha = 'b1ad50a4d0c444d5ed4f1c5919a1522494a03adb'
    }

    Describe 'Authoring module preparation' {
        BeforeEach {
            $script:saved = @{}
            foreach ($name in @('SOURCE', 'REF', 'LEGACY_VERSION', 'GALLERY_VERSION', 'RESOLVED_REF', 'RESOLVED_SHA', 'RUNNER_TEMP', 'GITHUB_WORKSPACE', 'GITHUB_OUTPUT')) {
                $script:saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            $env:SOURCE = 'gallery'
            $env:REF = ''
            $env:LEGACY_VERSION = ''
            $env:GALLERY_VERSION = '0.0.0'
            $env:RUNNER_TEMP = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $env:GITHUB_WORKSPACE = $env:RUNNER_TEMP
            $env:GITHUB_OUTPUT = Join-Path $env:RUNNER_TEMP 'output'
            New-Item -ItemType Directory -Path $env:RUNNER_TEMP -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $env:RUNNER_TEMP 'avm-gallery') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:root 'src' 'Avm.Authoring') `
                -Destination (Join-Path $env:RUNNER_TEMP 'avm-gallery' 'Avm.Authoring') -Recurse
            $global:AvmBootstrapSaveAttempts = 0
            Mock Get-PSResourceRepository { [pscustomobject]@{ Name = 'UserFeed'; Priority = 10; Uri = 'https://example.invalid/gallery' } }
            Mock Register-PSResourceRepository {}
            Mock Find-PSResource { [pscustomobject]@{ Version = [version]'0.0.0' } }
            Mock Save-PSResource {
                $global:AvmBootstrapSaveAttempts++
                $destination = Join-Path $Path 'Avm.Authoring'
                Copy-Item -LiteralPath (Join-Path $script:root 'src' 'Avm.Authoring') -Destination $destination -Recurse
            }
            Mock Start-Sleep
        }

        AfterEach {
            Get-Module Avm.Authoring | Where-Object { $_.ModuleBase.StartsWith($env:RUNNER_TEMP, [StringComparison]::OrdinalIgnoreCase) } |
                Remove-Module -Force
            foreach ($name in $script:saved.Keys) {
                $value = if ($null -eq $script:saved[$name]) { [NullString]::Value } else { $script:saved[$name] }
                [Environment]::SetEnvironmentVariable($name, $value, 'Process')
            }
            Remove-Variable AvmBootstrapSaveAttempts -Scope Global
            Remove-Variable AvmBootstrapManagerAttempts -Scope Global -ErrorAction SilentlyContinue
        }

        It 'imports the Gallery package prepared by the shared installer action' {
          & $script:prepare | Out-Null
          $moduleRoot = Join-Path $env:RUNNER_TEMP 'avm-package' 'Avm.Authoring'
          @(Get-Module Avm.Authoring | Where-Object ModuleBase -EQ $moduleRoot).Count | Should -Be 1
          Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | Should -Match '^artifact=avm-authoring-[0-9a-f]{32}'
        }
        It 'fails closed when the repository build cannot start' {
            $env:SOURCE = 'repo'
            { & $script:prepare } | Should -Throw
            Should -Invoke Find-PSResource -Exactly 0
            Should -Invoke Save-PSResource -Exactly 0
            Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
        }

        It 'builds and imports the selected repository module without a Gallery release' {
            $env:SOURCE = 'repo'
            $env:RESOLVED_REF = 'candidate'
            $env:RESOLVED_SHA = 'faf10e96bc16002170addd1bcfe91b78bb897c02'
            $source = Join-Path $env:GITHUB_WORKSPACE 'authoring-source'
            New-Item -ItemType Directory -Path $source -Force | Out-Null
            foreach ($name in @('build.ps1', 'build', 'src')) {
                Copy-Item -LiteralPath (Join-Path $script:root $name) -Destination $source -Recurse
            }
            $management = Join-Path $source 'repository-management'
            New-Item -ItemType Directory -Path $management -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:root 'repository-management' 'repository-management.build.ps1') -Destination $management
            $childScript = @'
$ErrorActionPreference = 'Stop'
$prepare = [scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:AVM_PREPARE)))
& $prepare | Out-Null
$module = Get-Module Avm.Authoring
$expected = Join-Path $env:RUNNER_TEMP 'avm-package' 'Avm.Authoring'
if ($module.ModuleBase -cne $expected) { throw 'The prepared module was not imported.' }
& $module {
    $script:lookupCalls = 0
    function script:Get-AvmLatestModuleVersion { $script:lookupCalls++; throw 'Unexpected Gallery lookup.' }
}
$records = @(Invoke-Avm -SkipModuleVersionCheck version 3>&1)
$version = $records | Where-Object { $_ -isnot [Management.Automation.WarningRecord] }
if (-not @($records | Where-Object { $_ -is [Management.Automation.WarningRecord] -and $_.Message -match 'version check was skipped' }).Count) {
    throw 'The CLI did not apply the requested freshness-check skip.'
}
if ((& $module { $script:lookupCalls }) -ne 0) { throw 'The CLI contacted the Gallery for freshness.' }
if ($version.Version -cne '0.0.0') { throw 'The prepared CLI returned an unexpected version.' }
'@
            $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $prepareEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:prepare.ToString()))
            & $script:module {
                param($Executable, $Encoded, $PrepareEncoded)
                Invoke-AvmProcess -FilePath $Executable -ArgumentList @('-NoProfile', '-EncodedCommand', $Encoded) `
                    -EnvVars @{ AVM_PREPARE = $PrepareEncoded; AVM_TEST_RUN_ID = $null; AVM_TEST_SKIP_MODULE_VERSION_CHECK = $null } | Out-Null
            } $pwsh $encoded $prepareEncoded
            $manifest = Join-Path $env:RUNNER_TEMP 'avm-package' 'Avm.Authoring' 'Avm.Authoring.psd1'
            $builtManifest = Join-Path $source 'out' 'Avm.Authoring' 'Avm.Authoring.psd1'
            (Get-FileHash -LiteralPath $manifest).Hash | Should -BeExactly (Get-FileHash -LiteralPath $builtManifest).Hash
            Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeTrue
        }
    }

    It 'resolves a <Label> once to an immutable commit' -ForEach @(
        @{ Label = 'full SHA'; Ref = 'faf10e96bc16002170addd1bcfe91b78bb897c02' }
        @{ Label = 'branch'; Ref = 'feature/authoring' }
        @{ Label = 'branch with legal punctuation'; Ref = 'feature/candidate+test;safe' }
        @{ Label = 'tag'; Ref = 'v0.35.0' }
    ) {
        $result = Invoke-RepositorySelectionFixture -Ref $Ref -Fixture @{ commits = @{ $Ref = $script:sha } }
        $result.ExitCode | Should -Be 0
        $selected = $result.StdOut | ConvertFrom-Json
        $selected.outputs.sha | Should -BeExactly $script:sha
        $selected.outputs.ref | Should -BeExactly $Ref
        $selected.calls | Should -Be @($Ref)
    }

    It 'selects the highest stable version tag, not a prerelease or lexical maximum' {
        $fixture = @{
            tags = @(
                @{ name = 'v0.9.0'; commit = @{ sha = $script:otherSha } }
                @{ name = 'v0.35.0-rc.1'; commit = @{ sha = $script:otherSha } }
                @{ name = 'v0.35.0'; commit = @{ sha = $script:sha } }
            )
            commits = @{ $script:sha = $script:sha }
        }
        $result = Invoke-RepositorySelectionFixture -Ref '' -Fixture $fixture
        $result.ExitCode | Should -Be 0
        $selected = $result.StdOut | ConvertFrom-Json
        $selected.outputs.sha | Should -BeExactly $script:sha
        $selected.outputs.ref | Should -BeExactly 'v0.35.0'
        $selected.calls | Should -Be @('tags', $script:sha)
    }

    It 'fails closed for missing, unsafe and unresolved refs' {
        foreach ($ref in @('feature/../main', 'branch^invalid', 'missing')) {
            $result = Invoke-RepositorySelectionFixture -Ref $ref -Fixture @{ commits = @{} }
            $result.ExitCode | Should -Not -Be 0
            $result.StdOut | Should -BeNullOrEmpty
        }
        $result = Invoke-RepositorySelectionFixture -Ref '' -Fixture @{ tags = @(); commits = @{} }
        $result.ExitCode | Should -Not -Be 0
        $result.StdErr | Should -Match 'No stable repository version tag'
    }
}
