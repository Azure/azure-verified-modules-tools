# Release asset lookup

**Status**: complete
**Started**: 2026-09-23
**Updated**: 2026-09-23
**Branch**: `jaredfholgate-workflow-troubleshooting`

## Outcome

Make signed release publication find the exact archive and `SHA256SUMS` through
the release-ID asset endpoint when GitHub's tag lookup reports no assets. Keep
the existing published-release checks, signed-content validation, and Gallery
approval boundary. Do not rerun or publish a live release as part of this slice.

## Checklist

- [x] Inspect the failing run and compare GitHub's tag, release-ID, and asset-list responses.
- [x] Confirm the branch is based on current `main` and check related open work.
- [x] Download and validate the required assets by release ID.
- [x] Add focused regression coverage and update the release workflow contract.
- [x] Run the targeted checks and the required pre-commit gate.
- [x] Record the production retry prerequisite without triggering publication.

## Validation

- GitHub release `v0.17.1` (ID `394441403`) lists zero assets by tag but the
  signed archive and `SHA256SUMS` by release ID.
- A local, read-only invocation of the new downloader retrieved both release
  assets by ID. The 1,382,353-byte archive matched `SHA256SUMS`; no package was
  published.
- Focused downloader tests: 8 passed. All workflow-definition tests: 44 passed.
- `.\build.ps1 pre-commit`: layout and lint passed; 1,739 unit tests passed,
  9 skipped; 907 component tests passed, 1 skipped; 0 failures. The build
  completed with 52 warnings.

## Dependencies

The updated publisher must be merged before a production retry can use it.
Production workflow dispatch, approvals, and Gallery publication remain out of
scope for this change.
