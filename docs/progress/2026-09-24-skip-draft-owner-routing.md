# Skip drafts in pull request reviewer routing

**Status**: complete
**Started**: 2026-09-24
**Updated**: 2026-09-24
**Branch**: `jaredfholgate-skip-draft-owner-routing`

## Outcome

Scheduled reviewer routing does not select draft pull requests. Once a draft
becomes ready for review, its updated timestamp makes it eligible for the
scheduled lookback. An explicitly selected draft remains guarded from edits.

## Checklist

- [x] Exclude drafts from the scheduled candidate list without changing the
      single-pull-request guard.
- [x] Test draft exclusion and the ready-for-review lookback.
- [x] Run the local pre-commit gate.

## Validation

`./build.ps1 pre-commit`: layout and lint passed; 1,810 unit tests passed,
9 skipped; 799 component tests passed. The build completed with 0 errors.

## Blockers or dependencies

None.
