# Sync changed-file diagnostics

**Status**: complete
**Started**: 2026-08-11
**Updated**: 2026-08-11
**Branch**: `jaredfholgate-report-sync-changed-files`

## Outcome

Identify the exact managed-file drift reported by the initial repository-sync
cutover test and make verbose `avm sync` output report each changed
repository-relative path and operation without exposing file contents.

## Checklist

- [x] Diagnose the single planned managed-file update from the cutover run.
- [x] Add focused changed-file operation logging.
- [x] Cover create, update, delete, and unchanged behavior.
- [x] Update the changelog.
- [x] Complete the repository validation gate.
- [x] Commit, push, and open the focused pull request.

## Validation

- Reproduced run `31487093870` against target commit
  `2160df75ffdd35ba2f3d7c1a932997110796a5ba` and managed source commit
  `9b01b78b531620ec28230cec7db20057439a4fb8`.
- Identified `avm` as the only planned update. Its bytes, SHA-256, Git blob
  hash, BOM state, and LF counts are identical; only the Git mode differs
  (`100755` in the target and `100644` in the managed source).
- Confirmed the improved reproduction reports
  `sync: update avm (mode 100755 -> 100644)`.
- `./build.ps1 test`
- `./build.ps1 component`
- `./build.ps1 pre-commit`
- Hosted CI initially failed the two new exact-message unit assertions on all
  three operating systems because GitHub Actions enables ANSI log colouring.
  The assertions now strip ANSI formatting before comparing message text.

## Blockers or dependencies

None.
