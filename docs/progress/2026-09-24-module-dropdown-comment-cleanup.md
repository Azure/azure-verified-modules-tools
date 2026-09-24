# Remove obsolete commented module dropdown entries

**Status**: complete
**Started**: 2026-09-24
**Updated**: 2026-09-24
**Branch**: jaredfholgate-dropdown-generator-cleanup

## Outcome

The central module-list sync removes obsolete commented-out `avm/` dropdown
options while retaining active catalog options in category order and preserving
unrelated YAML content.

## Checklist

- [x] Update the dropdown resolver and its focused Pester tests.
- [x] Verify comment-only drift and repeat-sync idempotence.
- [x] Run the repository's pre-commit gate.
- [x] Record the completed slice and validation.

## Validation

- `./build.ps1 test -TestName '*ModuleListSync*'`: 14 passed.
- `./build.ps1 test -TestName '*Resolve-AvmModuleDropdownSync*'`:
  6 passed, including preservation of active options and unrelated YAML,
  removal of four obsolete pattern options, and a no-change second sync.
- `./build.ps1 pre-commit`: layout and lint passed; 1,808 unit tests
  passed (9 skipped) and 799 component tests passed. The build completed
  with 50 test-generated warnings and no errors.

## Blockers or dependencies

None. The separate bicep-registry-modules test cleanup belongs to the parent
session.
