# Repository sync migration cleanup

**Status**: complete
**Started**: 2026-10-06
**Updated**: 2026-10-06
**Branch**: `jaredfholgate-repository-sync-migration-cleanup`

## Outcome

Remove the completed, one-off BAMI split-state consolidation code and its
exclusive workflow wiring, modes, tests, fixtures, and operational instructions.
Ordinary repository sync retains one Terraform root, one canonical
`<repoId>.tfstate`, one guarded plan/apply, and the existing identity,
ownership, tenant, subscription, group, and stale-state protections.
Plan-only runs no longer require migration readiness.

This is source cleanup only. Former source states, legacy ordinary states,
backup archives, recovery/completion records, inherited overlaps, and cloud
resources remain retained and untouched. No live backend reads, plans,
applies, workflow controls, credentials, or merge are part of this slice.

## Checklist

- [x] Read repository instructions and active or blocked slices.
- [x] Confirm current main and check for competing cleanup work.
- [x] Confirm the successful production cutover satisfies the cleanup gate.
- [x] Trace all migration helpers and retain genuinely shared sync behavior.
- [x] Remove migration-only source, wiring, tests, fixtures, and instructions.
- [x] Verify ordinary preview/apply control flow and safeguards.
- [x] Run targeted checks and the full unfiltered local gate.

## Validation

Baseline: `1e5578535faa0f4f0889eebedeb7eb4c342c3375`, the main commit of
[the final migration correction](https://github.com/Azure/azure-verified-modules-tools/pull/227).
The [production run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37429326384)
completed successfully on this exact commit. The coordinating session
verified all 231 jobs, including all 229 ordinary sync jobs and their sync
steps. This session independently confirmed the run's completed/success
status and exact head using GitHub metadata, without reading live state.

Targeted validation passed:

- `.\build.ps1 test-repository-management`: 785 passed, none failed or skipped.
- Focused ordinary-sync, saved-plan, and project-logging component checks:
  82 passed, none failed or skipped.
- `.\build.ps1 test-tenant-terraform,test-workflows`: 19 root Terraform tests,
  15 child-module Terraform tests, and 54 workflow tests passed. Terraform used
  mocked providers and synthetic local state, not live plans or applies.
- All 12 retained functions in `TestTenant.ps1` match the baseline exactly.
  Only the unused split-state key helper was removed. Ordinary Terraform,
  sync drivers, logging, configuration, and general authoring CI are unchanged.
- No remaining runtime or test references to the deleted migration machinery.

The full, unfiltered `.\build.ps1 pre-commit` gate passed with
`AVM_COMPONENT_SHARD_COUNT=1`, without a global `AVM_OFFLINE` override:
layout and lint passed; 2,897 unit tests and 1,261 component tests passed,
with zero failures and zero not-run tests. The existing nine unit skips and
one component skip remain; no exclusions or new skips were added.

This record closes implementation and local validation. The published commit,
review URL, and exact-head automatic CI evidence are reported in the review
and session handoff after publication, without an evidence-only commit.

## Blockers or dependencies

None for implementation or local validation. The user controls merge and
subsequent production runs. Internal team documentation is coordinated
separately; this branch does not edit that repository.
