# Resource Graph telemetry migration guidance

**Status**: complete
**Started**: 2026-09-25
**Updated**: 2026-09-25
**Branch**: `jaredfholgate-resource-graph-telemetry-migration`

## Outcome

Document how to rotate the published Resource Graph telemetry prefix to a new
seven-character lowercase hexadecimal Bicep resource prefix while retaining its
previous value in version-1 module metadata.

## Checklist

- [x] Confirm the preceding telemetry schema change is merged and no matching
      open branch or pull request exists.
- [x] Update the schema description without changing its version, URI, or
      accepted metadata.
- [x] Confirm the existing component tests cover the old current prefix, the
      rotated current prefix with the historical alternative, and rejection of
      the historical prefix on unrelated modules.
- [x] Run the local pre-commit gate.

## Validation

`.\build.ps1 pre-commit` passed: layout and lint clean, 1,831 unit tests
passed (9 skipped), and 823 component tests passed. The build reported
50 test-generated warnings and no errors.

## Blockers and dependencies

None. The Bicep module migration is a separate change.
