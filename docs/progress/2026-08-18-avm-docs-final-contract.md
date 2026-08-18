# AVM docs final configuration contract

**Status**: complete
**Started**: 2026-08-18
**Updated**: 2026-08-18
**Branch**: `jaredfholgate-avm-docs-parity-template`

## Outcome

Align the AVM documentation parity utility with the accepted Bicep
`bicepconfig.json` documentation contract and `docs generate` command shape.

## Checklist

- [x] Use a root `bicepconfig.json` with documentation-scoped example
  reassignments.
- [x] Use standard configuration discovery and copy the configuration into the
  validation working checkout.
- [x] Use `docs generate --stdout` for semantic model output.
- [x] Represent exported types and variables in semantic templates and indexes.
- [x] Validate JSON, PowerShell syntax, and the pre-commit gate.

## Validation

- `bicepconfig.json` parses as JSON, contains only the `documentation` section,
  and retains all three example reassignments.
- Both parity scripts parse without PowerShell syntax errors.
- Static contract checks confirm no `--config-file-path` or `docs output`
  invocations remain.
- `./build.ps1 pre-commit` passed.
