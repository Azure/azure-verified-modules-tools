# Disable example telemetry

**Status**: complete
**Started**: 2026-09-17
**Updated**: 2026-09-17
**Branch**: `jaredfholgate-telemetry-disable-rule`

## Outcome

Add an example-only MaPoTF rule that sets `enable_telemetry = false` on module
calls when the called module declares that input. Preserve modules without the
input and keep root/module behavior unchanged.

## Checklist

- [x] Inspect module-input discovery and example profile composition.
- [x] Add the scoped rule and wire packaging and profile selection.
- [x] Cover missing, enabled, disabled, and unsupported telemetry inputs.
- [x] Verify repeat runs, drift checking, and example file-layout preservation.
- [x] Update the directly related documentation and changelog.
- [x] Run the local gate.

## Validation

- `./build.ps1 pre-commit`: passed with 1,517 unit tests and 530 component
  tests, nine skips, and zero errors. The build reports warnings.
- `./build.ps1 integration -TestName 'Integration: MAPOTF example telemetry*'`:
  16 passed, zero skipped, using pinned MaPoTF 0.2.1, Terraform 1.15.8, and
  terraform-docs 0.24.0.
- Real-binary coverage includes required/optional inputs, existing values and
  expressions, inline calls, utility subdirectories, unsupported spellings,
  missing sources, multiple files, first-pass ordering, idempotence, and
  snapshot restoration during drift checks.
- All five canonical examples remain unchanged by the new profile and by
  regeneration of their README files. Validation uses local fixtures only;
  no Azure deployment or production operation was run.

## Implementation notes

- Uses MaPoTF's `module_source.variables` rather than module names or text
  matching, including required inputs and local subdirectory sources.
- Examples run after root/submodule targets, then apply `example,common`.
  This observes newly generated inputs and orders inserted arguments in one run.
- Canonical example fixtures and their generated README snippets include the
  opt-out. Root/submodule calls and source-module defaults remain unchanged.
- Real-binary checks exposed MaPoTF's single-line insertion and update/order
  composition limitations. Only inline calls are expanded before insertion;
  common attribute ordering runs after the update.

## Blockers and dependencies

None identified.
