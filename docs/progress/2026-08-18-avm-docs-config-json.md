# AVM docs configuration JSON correction

**Status**: complete
**Started**: 2026-08-18
**Updated**: 2026-08-18
**Branch**: `jaredfholgate-avm-docs-parity-template`

## Outcome

Remove the trailing comma that prevents Bicep from parsing the AVM documentation
parity `bicepconfig.json`.

## Checklist

- [x] Remove the trailing comma after the final example reassignment.
- [x] Validate strict JSON parsing and targeted PowerShell syntax.

## Validation

- .NET strict JSON parsing with trailing commas disabled passed.
- Both parity scripts parse without PowerShell syntax errors.
- `./build.ps1 pre-commit` passed.
