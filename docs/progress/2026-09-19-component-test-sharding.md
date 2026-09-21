# Component test sharding

**Status**: complete  
**Started**: 2026-09-19  
**Updated**: 2026-09-19  
**Branch**: jaredfholgate-component-test-sharding

## Outcome

Shard the `component` Pester tier across independent `pwsh` child processes while preserving focused single-process debugging, test-result publication, and the existing `component OK: N passed, M skipped` contract.

## Checklist

- [x] Add a shard worker entry point.
- [x] Add deterministic shard planning and aggregation to the build script.
- [x] Route the `component` task through sharding by default, with single-process fallback for one shard or `-TestName`.
- [x] Add unit coverage for planner partitioning.
- [x] Validate focused component filtering and full pre-commit.
- [x] Commit, push, and open a pull request.

## Validation

- `./build.ps1 test -TestName 'New-AvmPesterShardPlan*','Get-AvmComponentShardCount*'` - passed, 5 selected tests.
- `./build.ps1 component -TestName 'Component: Invoke-AvmTestUnit*'` - passed, 2 selected component tests; used the single-process fallback because `-TestName` was active.
- `./build.ps1 component` - passed using 6 shards; `component OK: 831 passed, 1 skipped`; wall time 154.1 seconds versus the saved baseline component duration of about 708 seconds. The saved baseline XML came from the unrelated metadata-display-name branch and included two tests from PR https://github.com/Azure/azure-verified-modules-tools/pull/151 while missing one current-main component test, so the current branch's aggregate is 832 total cases: 831 successful and 1 ignored.
- `./build.ps1 pre-commit` - passed with existing warnings; component shard portion completed in 2:31.57 and the full gate in 6:04.70. PSScriptAnalyzer hit the known transient `NullReferenceException` retry path on the first three attempts and then completed.
- Changed-file encoding check - passed: no UTF-8 BOM and no CR bytes in the touched `.ps1` / `.md` files.

The default shard count is `min([Environment]::ProcessorCount, 6)`. Set `AVM_COMPONENT_SHARD_COUNT=1` to force the prior single-process component path, or any integer greater than 1 to choose a specific shard count. `-TestName` always uses the single-process path for focused debugging.

## CI fix: `Install-Module` not resolvable in sharded workers

PR https://github.com/Azure/azure-verified-modules-tools/pull/152 was CI-red on all three OSes after the
initial push. `tests/Pester/Component/RepositoryCreation.Component.Tests.ps1` and
`RepositoryCreation.EntryPoint.Component.Tests.ps1` both call `Mock Install-Module { ... }`, and Pester's
`Mock` requires the command to already be resolvable via `Get-Command`. The old single-process `component`
task happened to have `PowerShellGet` (which exports `Install-Module`) auto-loadable, because it ships
inside `$PSHOME\Modules` on this dev box's PowerShell 7 install. A freshly spawned shard worker only imports
`Pester`, so nothing pre-loads `PowerShellGet`, and GitHub-hosted runners do not reliably bundle/auto-load it
either (confirmed the failure reproduces on Ubuntu, macOS, and Windows CI runners alike, so it is not purely
an OS difference - it is about what's importable in a bare `pwsh` session).

Fix: both affected test files now define a local `Install-Module` stub function in `BeforeAll`, guarded by
`if (-not (Get-Command -Name Install-Module -ErrorAction SilentlyContinue))`, mirroring the existing pattern
already used in `tests/Pester/Unit/Workflows/AvmAuthoringInstallation.Tests.ps1`. This makes the mock target
resolvable regardless of whether PowerShellGet is present, without importing any real module or touching the
network. No changes were needed to `build/Invoke-AvmPesterShard.ps1` or `build/AvmPesterSharding.ps1`.

Validation:
- Confirmed root cause locally: `Get-Module -ListAvailable -Name PowerShellGet` resolves to
  `C:\program files\powershell\7\Modules\PowerShellGet`, i.e. bundled with the PS7 installer, which explains
  why the local single-process and sharded runs both masked the issue on this machine.
- `./build.ps1 component -TestName '*publishes request metadata without forking*'` - passed (1 selected test,
  single-process fallback).
- `./build.ps1 component` - passed, 832 passed / 1 skipped, 0 failed, wall time 174.0 seconds (6 shards).
- `./build.ps1 pre-commit` - passed: unit tests 1664 passed / 8 skipped, component tier 832 passed / 1
  skipped, 0 failures anywhere; total wall time 394.5 seconds (~6m35s).

## Follow-ups

- `New-CatalogFixture` in `tests/Pester/Component/ModuleCatalog.Component.Tests.ps1` is rebuilt per test; hoisting it to `BeforeAll` where tests do not mutate it would cut a large share of that file's current runtime.
- The argv-recording stubs under `tests/fixtures/bin/` route through `pwsh -File`; a native shim would remove a process start per invocation.
- Windows Defender exclusions for the repo and the TestDrive temp path typically save 20-30% on filesystem-heavy suites.

## Blockers

- None.
