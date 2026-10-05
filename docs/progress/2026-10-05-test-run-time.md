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
| Final gate | 7m38s | 1m52s | 3m53s |

- Final gate: layout 5.1s, lint 1m47s; unit 2,963 passed and 9 skipped across six shards; component 1,280 passed and 1 skipped. The added unit tests cover shard count, isolation and stale-result clean-up. Component shard finish times were within 46s of each other.
- Component times vary between runs because of machine load. The unit tier gained the most.
- Serial fallback: `AVM_UNIT_SHARD_COUNT=1 ./build.ps1 test` passed 2,962 tests in 4m23s.
- A transient PSScriptAnalyzer error ("pipeline already running" or a null reference) passed on rerun with no changes.
