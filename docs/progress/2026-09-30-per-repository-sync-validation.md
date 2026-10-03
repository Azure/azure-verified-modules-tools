# Per-repository sync validation

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Run Prepare, Validate, and Publish as dependent jobs for each repository
independently. A failed preparation must skip that repository's validation;
a failed validation must skip its publication, without suppressing checks
for other repositories in the matrix.

## Checklist

- [x] Move the repository-specific job chain into a reusable workflow
      invoked once per repository by the existing matrix.
- [x] Preserve environment isolation, plan-only behavior, credentials,
      issue reporting, and project-item sync.
- [x] Cover per-repository dependencies and input forwarding in workflow
      tests.
- [x] Pass the local pre-commit gate, commit, and push the change.

## Validation

`actionlint` passed for the dispatcher and per-repository reusable workflow.
Focused unit and component tests verified input forwarding, independent
matrix invocations, job dependencies, identity isolation, backend resolution,
and installer behavior. `./build.ps1 pre-commit` passed with 1,952 unit
tests, 937 component tests, 9 platform skips, and no errors. No live
repository sync or Azure operation was started for this slice.

## Blockers or dependencies

The approved BAMI canary
[run 36719510774](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36719510774)
failed preparation because the example module's telemetry unit test has a
non-empty `modtm` mock. The module must be updated separately; this workflow
change prevents its missing candidate from causing redundant downstream
failures. No live sync is authorized as part of this slice.
