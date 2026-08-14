# AVM documentation parity template

**Status**: complete
**Started**: 2026-08-14
**Updated**: 2026-08-14
**Branch**: `jaredfholgate-avm-docs-parity-template`

## Outcome

Add the finalized Scriban templates, semantic model index template, and
PowerShell verifiers for Bicep AVM README documentation parity.

## Checklist

- [x] Add the templates and verifier under `scripts/avm-docs/`.
- [x] Add all-module reporting with genuine compilation failures retained.
- [x] Document invocation and validation scope.
- [x] Validate PowerShell syntax and the repository pre-commit gate.

## Dependencies

- Validated against `Azure/bicep-registry-modules` commit
  `55c62d45eaf6675c09bf663616c3e7fdd8c4560f`.

## Validation

- `Test-AvmDocsParity.ps1` parses without PowerShell syntax errors.
- The finalized full run compared 573 modules in `00:06:13.5504992`: 572
  generated READMEs matched byte-for-byte, one module had a genuine compilation
  failure, and 49 semantic-model mismatches were retained in detailed reports.
- The failure was `avm/ptn/app/container-job-toolkit` with BCP426, BCP104,
  BCP287, and BCP036; no README was generated for that module.
- Of the semantic-model mismatches, 34 involved parameters and 15 involved
  example names.
- The final templates match their validated source after LF normalization, both
  PowerShell scripts parse, and `./build.ps1 pre-commit` passed.
