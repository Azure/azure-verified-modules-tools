# Telemetry branch reconciliation with current main

**Status**: complete
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Reconcile the telemetry branch with newer main changes without reverting
purposeful work or rewriting published history.

## Checklist

- [x] Inspect new main changes and the actual conflicting paths.
- [x] Preserve both current-main behavior and the qualified telemetry changes.
- [x] Run the full local gate before committing the merge.

## Evidence

The live review reported merge conflicts while MaPoTF 0.3.0 release
verification was pending. The feature worktree was clean before this record.
The six supported platform archives and checksums are published, but the
checksum signing action was still queued. Do not change the production pin
until that separate verification gate succeeds.

New main commit `b0ba22f` qualifies the Bicep distribution's canonical
scaffold telemetry. Its package-validation scripts, extracted-module import
helper and expanded checks are preserved. The only conflict was in the
scaffold convention test: keep the canonical shipped-scaffold test name and
compiled description from main, together with the branch's explicit assertion
on the packaged source description. The scaffold source matches current main.
Published feature history is retained through a merge, not rewritten.

## Validation

The full `./build.ps1 pre-commit` gate passed layout, lint with no findings,
2,644 unit tests (nine existing skips), and 1,291 component tests (one existing
skip), with zero failures. The merge includes
`b0ba22f2fca81e4e068414e7f20bb703acd37de4`; the four new package-import
component cases pass alongside the telemetry branch's existing checks.

## Blockers or dependencies

No release operation, protected approval, module publication or merge into
main is authorized by this reconciliation.
