# Metadata and BAMI integration

**Status**: complete
**Started**: 2026-09-15
**Updated**: 2026-09-15
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Integrate latest main/BAMI changes into the three open metadata branches while
preserving metadata behavior and adapting workflow protections where necessary.
The user approved merging main into the published branches rather than rebasing
and force-pushing. The shared public workflow-template change is already merged.
The user also explicitly approved retaining the new BAMI activation gate,
`AVM_BAMI_TEST_TENANT_SYNC_ENABLED`.

## Checklist

- [x] Integrate latest tools main into the metadata implementation.
- [x] Coordinate the separate ownership and Bicep metadata branch updates.
- [x] Confirm merged public template behavior remains compatible with BAMI.
- [x] Preserve preview CSV outputs, manual-only backfill, and metadata protections.
- [x] Resolve workflow ambiguities with the user instead of guessing.
- [x] Run relevant checks, review the integration, commit, and push.

## Validation

Tools main `ed61c747fa9a1672c8bd18262dde1162ccec604e` is merged locally.
Resolved workflow conflicts retain strict dry runs, the separate BAMI variable
job/token/gate, and metadata-only isolation from tenant/identity processing.
Focused checks pass: 27 unit cases and 28 component cases. The incoming
CODEOWNERS-job snapshot test was updated for the deliberately removed old
enable gate; its writer/token comparison remains exact.
Full offline `.\build.ps1 pre-commit` passed: 1,451 unit tests, 8 existing skips,
and 385 component tests, with zero errors. Claude Opus 5 reviewed the merge
resolutions and metadata/BAMI interactions and reported no findings.

The ownership branch integrated the same tools main and published
`f9c33783c4f1df332238c5e6ede1e0d7dbf42148` with green exact-head checks.
The Bicep metadata branch integrated main
`dfa9bab2c46e97b018b0d7b987537f738f6c0ef5` and published
`7fe0438eff8b2b9f4595ec39254c2e2a3213e6e7`. All 572 metadata files remain
byte-identical and valid against merged source; 387 offline cases and all
reported hosted checks pass. Its generic workflow has the same three
installed-actionlint diagnostics on main; no concurrency control was changed.

Public docs main `393639093c16889a7aee182e32f71b6f4f15c2dc` still includes the
merged metadata-only workflow exclusion. No follow-up template change is needed.

## Dependencies

No force-push, remote merge, production workflow execution, permission change,
or live workflow enable/disable is part of this task.
Fresh hosted checks are required on the published implementation merge commit.
