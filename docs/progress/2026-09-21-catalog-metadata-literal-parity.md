# Catalog metadata literal parity

**Status**: complete
**Started**: 2026-09-21
**Updated**: 2026-09-21
**Branch**: `jaredfholgate-fix-metadata-descriptions`

## Outcome

Stop module catalog collection from enforcing `metadata.json` description parity
with `main.bicep`. The catalog treats module metadata as its source of truth,
and source-literal comparison is not a catalog validation requirement.

## Checklist

- [x] Identify the catalog snapshot failure and its source-literal validation.
- [x] Remove the Bicep source-literal check from catalog collection.
- [x] Add component coverage for differing Bicep and metadata descriptions.
- [x] Update the module catalog contract documentation.
- [x] Run the focused component test.
- [x] Run the pre-commit gate.
- [ ] Commit, push, and create a pull request.

## Validation

- `./build.ps1 component -TestName '*uses Bicep metadata descriptions*'` passed
  (1 test).
- `./build.ps1 pre-commit` passed layout but was stopped during the repository's
  repeated transient PSScriptAnalyzer retries at the requester's direction.
