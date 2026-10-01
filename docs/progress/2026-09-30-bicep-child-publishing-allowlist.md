# Bicep child publishing allowlist

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Completed**: 2026-09-30
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Cover the pinned registry compliance assertion M:131 for versioned Bicep
children. Read the repository checkout's authoritative
`utilities/pipelines/staticValidation/compliance/helper/child-module-publish-allowed-list.json`
at check time, rather than shipping a snapshot or calling a service. Accept
versioned children only when their exact canonical `avm/...` path appears in
the validated `allowed-child-modules` array. Missing, linked, mis-cased,
unreadable or invalid allowlists must produce a named failure when any child
has a version file. Do not require the file for unversioned children.

## Checklist

- [x] Implement strict checkout-local allowlist loading and child checks.
- [x] Add passing and failing component fixtures for root, children,
      invalid paths and missing or malformed inputs.
- [x] Update the pinned coverage ledger without masking other incomplete
      convention families.
- [x] Independently review, run `./build.ps1 pre-commit`, commit and push
      this slice to the existing review.

## Validation

The registry's pinned checkout has 333 entries, each matching the required
canonical path shape; the check uses that file at runtime, not a copy of its
contents. Focused component fixtures exercise allowed and unlisted children,
missing or malformed lists, invalid entries, duplicate paths, directory
casing, strict UTF-8 and invalid version filenames. Independent review found
that a final newline could be ignored by a regex `$` anchor and an unreadable
allowlist directory could interrupt repository-wide e2e discovery before
this rule ran. End-of-string anchors and named test-discovery failures now
cover both; an unavailable global test index cannot produce an empty-path
exception while checking duplicate `serviceShort` values. The unfiltered
`./build.ps1 pre-commit` passed layout, lint, 1,930 unit tests (nine skipped)
and 1,009 component tests (one Windows-only skipped); 49 warnings are from
exercised negative paths. Initial full-gate failure on new files' CRLF endings
was resolved by normalizing to UTF-8 without BOM and LF before the passing
gate. No MCR/Azure calls were made.

## Blockers or dependencies

No live MCR/Azure lookups, registry CI switch, release or merge are part of
this slice. Publication-aware changelogs/parent versions, README/API-version
checks, resource-folder singularization and telemetry literal parity remain
explicitly fail-closed until their separate slices are implemented.
