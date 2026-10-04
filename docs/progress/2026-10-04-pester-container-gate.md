# Fail the gate when a Pester test file fails

- Status: complete
- Started: 2026-10-04
- Branch: jaredfholgate-avm-authoring-refactor

## Outcome

A test file that fails to parse or fails in discovery, `BeforeAll` or `AfterAll` is reported by Pester as a failed container. Its tests are not counted as failed. The sharded component task and `script:Invoke-AvmPester` only checked `FailedCount`, so such a file was silently skipped and the gate stayed green. The repository-management task already checked containers.

## Changes

- `build/Invoke-AvmPesterShard.ps1` exits 1 when any container failed. That check runs before the "no tests ran" check, so a shard whose only file is broken reports a failure instead of exit 2.
- `script:Invoke-AvmPester` in `build/avm.build.ps1` throws and lists the failed files. This covers the unit, coverage, workflow-unit and integration tasks.
- Fixed the scoped Bicep e2e component file that had been hidden by the hole: a `$SubscriptionId:` interpolation parse error, a mock that wrote to a variable outside its scope, and an `AvmException` built outside module scope.
- Unit test runs a real shard with one passing file and one unparsable file, and expects exit 1 with one counted test. It fails against the previous script.

## Checklist

- [x] Shard and in-process container checks.
- [x] Regression test.
- [x] Scoped Bicep component tests repaired (20 pass).
- [x] `./build.ps1 pre-commit` green; commit and push.

## Validation

- Shard regression test fails against the old script and passes with the fix.
- `./build.ps1 pre-commit`: green in 11m07s (2,913 unit tests; no failed containers).
