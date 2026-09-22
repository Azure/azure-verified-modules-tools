# Required metadata validation

**Status**: complete
**Started**: 2026-09-22
**Updated**: 2026-09-22
**Branch**: `jaredfholgate-metadata-validation-checks`

## Outcome

Require valid metadata.json for module roots and children in both authoring
chains. Validate before tool resolution or mutating steps and stop on metadata
failure, reusing the existing Avm.Authoring validator.
Terraform discovery includes nested modules beneath `modules/`, excluding test,
example, hidden, and build directories. Bicep retains recursive module discovery.

## Checklist

- [x] Require metadata and run validation first in pre-commit and pr-check.
- [x] Cover module discovery, fail-fast behavior, diagnostics, and valid chains.
- [x] Update affected fixtures and authoring documentation.
- [x] Run the local gate, commit, and push.

## Validation

`.\build.ps1 pre-commit` passed: layout, lint, 1,518 unit tests (9 skipped),
and 903 component tests (1 skipped), with no failures. The gate reported 55
warnings from exercised warning paths. Targeted tests exposed accumulated mock
call history across two invocations within one test; the regression helper now
tracks each invocation independently.

Real-binary integration fixtures and chain assertions were updated; the
network/Azure-dependent integration suite was not run.

## Dependencies

Bicep registry workflow and publishing integration is being implemented in a
separate bicep-registry-modules worktree using the latest published
Avm.Authoring validator. No production publishing will be run.
