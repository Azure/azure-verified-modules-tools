# Workflow unit test OS split

**Status**: complete
**Started**: 2026-09-21
**Updated**: 2026-09-21
**Branch**: `jaredfholgate-workflow-unit-test-os`

## Outcome

Keep Avm.Authoring layout, lint, coverage, component, and integration checks on
the existing Windows, Linux, and macOS CI matrix, but run workflow-definition
unit tests only on Ubuntu because the workflows they validate run only on
Ubuntu-hosted agents.

## Checklist

- [x] Split workflow-definition unit tests out of the three-OS CI build job.
- [x] Add a dedicated Ubuntu workflow unit-test job and publish its NUnit result.
- [x] Keep Avm.Authoring module tests and integration checks on the existing
      three-OS matrix.
- [x] Validate the targeted build tasks.

## Validation

- `./build.ps1 test-workflows,ci` (first run exposed a stale contract-test
  count; rerun passed after updating it)
- `./build.ps1 ci`
- `./build.ps1 pre-commit`
- `./build.ps1 test-workflows`

## Blockers or dependencies

- None.
