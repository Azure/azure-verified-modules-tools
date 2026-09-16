# Metadata consolidation and deprecation

**Status**: complete
**Started**: 2026-09-16
**Updated**: 2026-09-16
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Consolidate the metadata ownership changes into the existing tools
implementation review, then close the superseded ownership review after
verified inclusion. Preserve the engineering-only final metadata rule and all
current metadata, BAMI, and preview-publication safeguards.

Derive deprecation from existing authoritative signals: `DEPRECATED.md` in a
Bicep module directory, and GitHub's archived flag for a Terraform repository.
The user confirmed these signals after an interrupted question; no new
metadata lifecycle field is being introduced.
Root Bicep deprecation also applies to descendants; a child's marker affects
only that child and its descendants. Terraform archival applies repository-wide.

The user also approved flattening `owners` to username/qualified-team strings,
removing `tier` and its catalog/configuration automation, and removing the
redundant authored `schemaVersion` while retaining the required versioned
`$schema` reference. All consumers and the Bicep backfill must use the new shape.

## Checklist

- [x] Merge the published ownership branch into the implementation branch.
- [x] Carry deprecation evidence through source collection and offline generation.
- [x] Cover root/child deprecation and preserve existing retirement state.
- [x] Coordinate public maintenance documentation and consolidated rollout order.
- [x] Review, validate, commit, and push the consolidated change.

## Validation

- Full offline `.\build.ps1 pre-commit`: 1,509 unit tests passed, 8 existing
  skips, and all 473 component tests passed, with zero errors.
- `.\build.ps1 build`: package contains 24 functions and one alias. The input
  schema requires `$schema`, name, description, canonical identity, and flat
  owners; no tier or authored `schemaVersion` is present.
- Both native metadata integration cases passed: Bicep compiled output remains
  unchanged after non-telemetry edits, and provider-free Terraform reads the
  root and reduced child files without tier locals.
- The Bicep reshape is published at
  `7f3502d7fb3cb9aa4e6e37911b494205b9619230`; all 572 source/schema checks and
  351 ownership/release regressions pass. All 281 usernames and every unrelated
  field value are preserved, and the committed diff selects no release templates.
- Public maintenance documentation is published as a draft at
  `e6339e031b86211080ab2d71f3802318ffe0654c`, with green reported checks.
- Claude Opus 5 reviewed the consolidated schema, lifecycle, publication,
  migration, creation, and ownership changes and found no significant issues.

## Dependencies

No remote merge, production workflow, permission change, or repository
archive/unarchive action is authorized. Canonical CSV replacement remains a
separate later change; generated CSVs continue using `test-` filenames.
Fresh hosted checks and verification that the ownership commit is an ancestor
of the published implementation are required before closing the superseded
ownership review. No history rewriting or branch deletion is required.
