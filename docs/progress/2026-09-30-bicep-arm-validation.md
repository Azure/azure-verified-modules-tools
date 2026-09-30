# Bicep ARM validation and what-if

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Run credentialed ARM validation and what-if for selected `tests/e2e/**/main.test.bicep`
examples through `avm test integration`. Do not create resource groups or
change authored files. Preserve Terraform integration behavior and keep the
cheap Bicep `avm test` build-only.

## Checklist

- [x] Discover exact-case test files and honor `.e2eignore`, including
      explicit-selector and nested-scope handling.
- [x] Compile unchanged Bicep sources, replace tokens in temporary ARM JSON,
      reject unknown tokens and unsupported scopes before calling Azure.
- [x] Validate and preview deployments with an explicit subscription,
      existing resource group, and scope-specific arguments.
- [x] Report attempted, passed and failed operations, plus what-if changes;
      missing or entirely ignored suites must report skipped, not passed.
- [x] Add mocked Azure CLI and Bicep tests for success, failure and safety,
      update directly related help and run the pre-commit gate.

## Validation

`./build.ps1 pre-commit`: layout and lint pass; 1,920 unit tests pass
(9 skipped), and 936 component tests pass across six partitions. The
17 Bicep component cases use mocked Bicep and Azure CLI processes.
`./build.ps1 coverage`: 73.42% (4,994 of 6,802 commands; 70% floor).

## Blockers or dependencies

The user was unavailable to decide the token strategy. Compile unchanged
sources and substitute only in temporary compiled JSON: no source mutation,
reversal, or potentially lossy cleanup. No live Azure execution is permitted
while implementing and testing this tier.
