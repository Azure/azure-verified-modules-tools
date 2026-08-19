# AVM docs configuration contract

**Status**: complete
**Started**: 2026-08-17
**Updated**: 2026-08-17
**Branch**: `jaredfholgate-avm-docs-parity-template`

## Outcome

Align the AVM documentation-parity configuration and its script references with
the final Azure/bicep documentation configuration contract.

## Checklist

- [x] Rename the configuration to `bicepdocsconfig.json`.
- [x] Add the Bicep docs configuration schema and explicit `main.bicep` input
  selection.
- [x] Preserve the example reassignment settings and update all references.
- [x] Validate JSON, PowerShell syntax, and the pre-commit gate.

## Validation

- `bicepdocsconfig.json` parses as JSON and contains the required schema,
  input include, input exclude, and three example reassignments.
- Both parity scripts parse without PowerShell syntax errors.
- `./build.ps1 pre-commit` passed.
