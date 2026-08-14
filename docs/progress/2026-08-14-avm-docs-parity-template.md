# AVM documentation parity template

**Status**: complete
**Started**: 2026-08-14
**Updated**: 2026-08-14
**Branch**: `jaredfholgate-avm-docs-parity-template`

## Outcome

Add the validated Scriban template, semantic model index template, and
PowerShell verifier for Bicep AVM README documentation parity.

## Checklist

- [x] Add the templates and verifier under `scripts/avm-docs/`.
- [x] Document invocation and validation scope.
- [x] Validate PowerShell syntax and the repository pre-commit gate.

## Dependencies

- Validated against `Azure/bicep-registry-modules` commit
  `55c62d45eaf6675c09bf663616c3e7fdd8c4560f`.

## Validation

- `Test-AvmDocsParity.ps1` parses without PowerShell syntax errors.
- The templates match the validated prototype byte-for-byte; the verifier
  matches after LF normalization required by this repository.
- `./build.ps1 pre-commit` passed before finalizing the slice.
