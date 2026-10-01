# Bicep metadata and source consistency

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-metadata-independence`

## Outcome

Allow module-owned `metadata.json` descriptions and Bicep literal source
descriptions to serve their distinct purposes while preserving independent
source declarations and telemetry checks. Permit explicitly identified
metadata-only Bicep scopes in source validation without allowing published
modules to silently omit `main.bicep`.

## Checklist

- [x] Identify every description-equality check and source-less scope rule.
- [x] Update metadata/source validation and existing-source scaffolding.
- [x] Add focused unit and component regression coverage.
- [x] Align the implementation spec with the corrected invariant.
- [x] Pass the local pre-commit gate and prepare the slice for publication.

## Validation

`.\build.ps1 pre-commit` passed: layout and lint succeeded; 1,903 unit
tests passed (9 skipped), and 929 component tests passed across six groups.
The build reported 49 warnings from existing test fixtures and no errors.
`git diff --check` found no whitespace errors.

## Blockers or dependencies

Separate Bicep test-tier and policy/convention work is out of scope. Existing
registry workflows and `Set-AVMModule` remain in place.
