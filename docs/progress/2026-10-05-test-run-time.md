# Test run time

- Status: complete
- Started: 2026-10-05
- Completed: 2026-10-05
- Branch: jaredfholgate-avm-authoring-refactor
- Parent record: [2026-10-03-avm-authoring-refactor.md](2026-10-03-avm-authoring-refactor.md)

## Goal

Reduce the local `./build.ps1 pre-commit` wall time without changing the selected tests, coverage or failure detection.

## Baseline (same machine, 16 logical CPUs)

| Stage | Time | Tests |
| --- | --- | --- |
| layout | 1.4s | - |
| lint | 1m49s | - |
| test (unit, single process) | 5m34s | 2,959 passed |
| component (6 shards) | 4m49s | 1,280 passed, 1 skipped |
| Total | 12m14s | |

Findings:

- The unit tier ran in one process, so 332s of Pester time across 175 files was serial.
- `ModuleCatalog.Component.Tests.ps1` took 285s on its own. Because a file cannot be split across shards, its shard finished about 100s after the other five.
- Profiling one catalog case without contention (fixture 0.36s, inventory 0.96s, bundle 0.69s) showed that the code under test was not the bottleneck.

## Changes

- [x] Shard the unit tier with the existing shard planner. `AVM_UNIT_SHARD_COUNT=1` and `-TestName` keep the single-process path. `coverage` and CI remain single-process. The unit tier still excludes the `Integration` and `Component` tags.
- [x] Give unit shards their own short temp folder and `AVM_HOME` outside the repository. These folders are removed afterwards, and the runner warns if a unit test wrote to the isolated `AVM_HOME`. Component shards keep the normal temp folder: an isolated prefix pushed `TerraformRepositoryInitialization` git pack paths (already about 251 characters) over the Windows 260-character limit.
- [x] Split the module catalog component tests into `ModuleCatalog`, `ModuleCatalog.Transformation` and `ModuleCatalog.Lifecycle` files. They share `tests/Pester/Helpers/ModuleCatalogFixture.ps1`, and all 162 tests are unchanged.
- [x] Clear the tier's single-process and shard result files before each run, so a run in one mode never leaves stale results for CI upload or shard weighting.

## Validation

| Run | Total | Unit | Component |
| --- | --- | --- | --- |
| Baseline | 12m14s | 5m34s | 4m49s |
| Sharded run 1 | 9m17s | 2m10s | 5m45s |
| Sharded run 2 | 7m55s | 1m33s | 4m24s |
| Final gate (`6f88897`) | 7m38s | 1m52s | 3m53s |
| Corrected gate | 7m33s | 1m44s | 3m43s |

- Corrected gate: layout 8.6s, lint 1m57s; unit 2,965 passed and 9 skipped across six shards; component 1,280 passed and 1 skipped. No unit shard wrote to its isolated `AVM_HOME`.
- Correction after `6f88897`: the runner passed `<shard>\h` to the worker as `AVM_HOME` but checked `<shard>\avm-home` for writes, so the write warning could never fire. Both now use the same path. A runner-level test, in which a shard writes to `AVM_HOME`, fails on the old code and passes on the fix; a second test confirms there is no warning for a clean shard.
- Component times vary between runs because of machine load. The unit tier gained the most.
- Serial fallback at the same final test set: `AVM_UNIT_SHARD_COUNT=1 ./build.ps1 test` passed 2,965 and skipped 9 in 4m06s, matching the sharded run. Only `unit.xml` remained afterwards, so the earlier shard results were cleared. The earlier serial figure of 2,962 was measured before the stale-result test was added, and the sharded 2,963 included it. The two runner tests above account for the rest of the increase to 2,965.
- Hosted baseline (CI run 37307771430 at `fbb47aa`): Windows `ci-tests` 14m27s (coverage 7m36s, component 6m48s with shard durations 403/276/253/229s); Ubuntu 6m39s (coverage 3m01s, component 3m38s). Coverage stays single-process, so this slice only targets the uneven component shards there. No hosted run of the test workflow exists yet for this slice or its correction, so no hosted improvement is claimed, and the `fbb47aa` results are not validation of this slice.
- A transient PSScriptAnalyzer error ("pipeline already running" or a null reference) passed on rerun with no changes.
- After merging `main` (`d49e079`), hosted CI run 37328240715 passed lint, unit, component, coverage and workflow tests on all three OSes. All six integration jobs failed in one new test, `BicepExistingReferences`: an empty `InModuleScope` result unrolled to `$null`, and reading `.Count` on `$null` throws under the build's `Set-StrictMode -Version 3.0`. The test passed when run alone. The call site is now wrapped in `@()`, and the test passes under strict mode with Pester 5.7.1 and 6.2.0. The assertion is unchanged.
- Running `./build.ps1 integration` locally uses the developer's signed-in Azure CLI. The azurerm fixture's `terraform plan` then tries to register resource providers, which failed locally with 403 and passes in CI. Run integration tests in CI or with no Azure credentials available.
