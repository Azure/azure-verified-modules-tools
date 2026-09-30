# Read-only Bicep format drift checks

**Status**: complete
**Started**: 2026-09-26
**Updated**: 2026-09-26
**Branch**: `jaredfholgate-interactive-metadata-initialization`

## Outcome

Make Bicep `avm pr-check` report formatting drift without rewriting .bicep
or .bicepparam files. Keep ordinary `avm format` and `avm pre-commit` format
operations in place, with the same issue and result contract.

## Checklist

- [x] Confirm the installed Bicep formatter's read-only output matches its
      in-place formatting for both file types.
- [x] Implement read-only drift detection and propagate formatter failures.
- [x] Cover unchanged files, drift, read-only behavior, and CLI errors in tests.
- [x] Pass `./build.ps1 pre-commit`, commit, and push this separate slice.

## Validation

The pinned Bicep CLI's stdout output matched in-place formatted UTF-8 bytes
for `.bicep` and `.bicepparam`, including BOM and newline cases. Stdout mode
did not modify the source. All 11 focused engine unit tests passed, covering
unchanged files, both file types' drift, BOM-only drift, CLI errors, and
ordinary in-place formatting; local lint reports no findings.
A real formatter run on temporary module sources reported both files as drift
without writing either, then formatted both in ordinary mode and passed a
second drift check.
The full `./build.ps1 pre-commit` gate passed layout, lint, 1,840 unit tests
(9 skipped), and 845 component tests. The previous metadata correction's
hosted multi-platform CI run completed successfully before this slice's push.

## Blockers and dependencies

No blockers for this slice. Non-proposed Bicep scaffolding and static
pre-commit/pr-check generation remain separate follow-on work.
