# Metadata main conflict resolution

**Status**: complete
**Started**: 2026-09-16
**Updated**: 2026-09-16
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Resolve the latest-main conflict in
[#113](https://github.com/Azure/azure-verified-modules-tools/pull/113) with a
history-preserving merge, not a rebase or force-push.

The published metadata head is
`db2cf27af7befc4bf1e8dc271f2da084489c62df`. Incoming main is
`25f1f4b2ca24505f9e1888542172322a6be6bc4a`, containing the Terraform provider-alias
preservation fix from
[#124](https://github.com/Azure/azure-verified-modules-tools/pull/124).
The shared base is `ed61c747fa9a1672c8bd18262dde1162ccec604e`.

Preserve the complete metadata contract and two-team review policy, together with
the incoming tool pins, provider-version transform, and integration regressions.

## Checklist

- [x] Confirm the existing review is open and the worktree is clean.
- [x] Fetch main and identify the incoming change.
- [x] Merge main and resolve each conflict without discarding either change.
- [x] Check preservation and run the relevant local gates.
- [x] Prepare the verified merge for publication on the existing feature branch.

## Validation

- The only conflict was `CHANGELOG.md`. Keep both the metadata release notes and
  the incoming MAPOTF 0.2.1 note; no executable conflict resolution was needed.
- Incoming pins, provider-version transforms, integration tests, and their
  progress record are unchanged from main. The existing metadata implementation,
  schemas, workflow, two-team policy, and repository configuration are unchanged.
- `.\build.ps1 pre-commit` with `AVM_OFFLINE=1`: 1,513 unit tests passed,
  eight existing skips, and 473 component tests passed; no failures or
  unexecuted tests. Existing analyzer retries/warnings remain.
- `.\build.ps1 integration -TestName @('Integration: MAPOTF provider requirements*',
  'Integration: module metadata native readers*')`: 33 passed, no failures or
  skips; 40 unrelated tests excluded by name. This exercised normal pinned
  MAPOTF 0.2.1, provider-alias preservation, unchanged compiled Bicep metadata
  readers, and provider-free Terraform metadata readers.
- Native validation used no development-binary override or cloud operations.
  Process-local guards prevented host antivirus preference changes.

## Dependencies

Verify fresh exact-head hosted checks after publication and update the existing
review references. The established operator-approved rollout, Bicep Sync pause,
canonical CSV cutover, and process-adoption gates remain unchanged.
The subsequent user-requested removal of dual-source mode and source-CSV
row-removal guard are a separate implementation slice.

No remote main merge, production workflow dispatch, permissions change, or
workflow enable/disable is part of this work.
