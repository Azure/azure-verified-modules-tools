**Status**: complete
**Started**: 2026-10-07
**Updated**: 2026-10-07
**Branch**: `jaredfholgate-improve-upgrade-error`

## Outcome

Allow the `avm upgrade` command to run when the loaded `Avm.Authoring` module
is outdated, present a clear actionable message for other commands without the
`NotInstalled` error-category prefix.

## Checklist

- [x] Route `avm upgrade` to the authoring updater and bypass the version guard.
- [x] Improve stale-module error wording and error rendering.
- [x] Add focused regression coverage.
- [x] Run `./build.ps1 pre-commit`.
- [x] Commit and push the completed slice.

## Validation

- `./build.ps1 test` — passed; 369 unit tests passed.
- `./build.ps1 pre-commit` — passed; layout and lint passed, unit tests passed, and component validation reported 1,447 passed and 1 skipped.

## Blockers or dependencies

None.
