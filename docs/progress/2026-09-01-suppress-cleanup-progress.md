# Suppress cleanup progress

**Status**: complete
**Started**: 2026-09-01
**Updated**: 2026-09-01
**Branch**: `jaredfholgate-suppress-cleanup-progress`

## Outcome

Suppress PowerShell file-operation progress bars during build and internal
cleanup without hiding subprocess output or AVM status reporting.

## Checklist

- [x] Suppress build-wide PowerShell progress rendering.
- [x] Suppress recursive removal progress in module and maintenance cleanup.
- [x] Add regression coverage for the suppression contract.
- [x] Validate the complete pre-commit gate.

## Validation

- `./build.ps1 pre-commit` - 1019 unit tests passed, 8 skipped; 29 component
  tests passed; 0 failures.
- Captured gate output contained no recursive removal or file-size progress bars.

## Dependencies

None.
