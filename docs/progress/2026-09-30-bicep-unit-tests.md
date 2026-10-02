# Bicep Pester unit tests

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Run Bicep module unit tests and the existing registry compliance suite through
`avm test unit`, without changing the cheap build-only `avm test` command or
the registry's existing scripts and CI. Report discovered, passed, failed,
filtered, and explicitly skipped tests; no runnable tests must not look green.

## Checklist

- [x] Discover Bicep module roots, optional nested scopes and tests/unit suites.
- [x] Run registry compliance when available, with the same Pester data and
      pinned Bicep binary; expose tag/name filters and an explicit suite path.
- [x] Isolate Pester execution in a child PowerShell process so tests cannot
      change the caller's session. The user was unavailable to confirm this
      design choice; isolation is the safer default.
- [x] Preserve Terraform unit-tier behavior and update command help.
- [x] Cover routing, discovery, failures, skips, filters and nested scopes with
      unit and component tests.

## Validation

`./build.ps1 pre-commit`: layout and lint pass; 1,903 unit tests pass (9
skipped), with 919 component tests passing across six partitions.
`./build.ps1 coverage`: 72.9% (4,783 of 6,561 commands), above the 70% floor.

## Blockers or dependencies

The registry compliance suite imports registry-specific helpers and is not
packaged in Avm.Authoring. Standalone modules can run their own unit tests;
the suite runs when its registry checkout is present or explicitly supplied.
