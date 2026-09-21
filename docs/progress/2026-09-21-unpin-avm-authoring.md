# Do not enforce Avm.Authoring version

**Status**: complete
**Started**: 2026-09-21
**Updated**: 2026-09-21
**Branch**: `jaredfholgate-unpin-avm-authoring`

## Outcome

Allow every `Avm.Authoring` command to run with the currently imported version.
The explicit `avm update` command remains responsible for discovering and
installing PowerShell Gallery updates.

## Checklist

- [x] Identified the scheduled Bicep synchronization failure as the stale
  module-version guard.
- [x] Removed the runtime PowerShell Gallery lookup and stale-version failure.
- [x] Added regression coverage for dispatch without a Gallery lookup.
- [x] Marked source builds with manifest version `0.0.0`.
- [x] Run the local pre-commit gate.
- [x] Commit and push the completed slice.

## Validation

- `./build.ps1 test` passed.
- `./build.ps1 pre-commit` passed.

## Blockers or dependencies

- None.
