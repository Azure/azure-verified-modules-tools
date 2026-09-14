# Bicep metadata workflow integration

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Extend the Bicep management workflow introduced by
[#112](https://github.com/Azure/azure-verified-modules-tools/pull/112)
with opt-in metadata backfill. Reuse its shared repository-file publisher and
reconcile the Terraform metadata adapter with that publisher.

The user confirmed that Bicep `plan_only` must be a strict dry run with no
remote writes, and requested removal of the `AVM_CODEOWNERS_SYNC_ENABLED`
workflow gate. Metadata backfill remains manual-only and never auto-merges.
No production workflow or repository-variable change is executed here.

## Checklist

- [x] Integrate the merged shared publisher without losing metadata safeguards.
- [x] Add metadata backfill to the existing Bicep management workflow.
- [x] Make Bicep plans read-only and remove the obsolete enable gate.
- [x] Cover shared publication and both ecosystem adapters with regressions.
- [x] Update the operator documentation and run the repository gate.
- [x] Prepare the merged feature branch for publication to the existing review.

## Validation

- `.\build.ps1 pre-commit`: 1,232 unit tests passed, 8 skipped;
  284 component tests passed; no errors. Existing analyzer warnings remain
  non-blocking.
- `.\build.ps1 test-repository-management`: 205 tests passed.
- Strict dry runs perform no staging, commits, pushes, candidate creation, or
  merges. Review-only metadata apply creates a verified candidate without
  requiring merge capability.
- Bicep metadata preparation uses a full disposable checkout and an exact
  metadata/source changed-file allow-list. Terraform preserves its ordinary
  preparation/result contracts and uses a target-only token for backfill.
- Existing candidate identity, stale-head, content-scope, owner-diagnostic,
  and API/Git error guards remain covered.

## Blockers or dependencies

Reviewed seeds and explicit operator approval remain required for a live
backfill. Scheduled CODEOWNERS apply no longer requires the removed enable
variable, but its existing merge prerequisites remain in force. No production
workflow was dispatched, and no repository variable, target repository,
permission, or live backfill was changed.
