# Single-state repository sync

**Status**: complete
**Started**: 2026-10-04
**Updated**: 2026-10-04
**Branch**: `jaredfholgate-single-state-repository-sync`

## Outcome

Implemented one ordinary Terraform root, state, and plan/apply per repository for
GitHub configuration and BAMI test identity, federation, and membership edges.
Removed the separate identity provisioning apply without restoring retired
tenant resources or broadening permissions. Also removed the redundant GitHub
template block while ignoring its historic state, and folded full workflow
diagnostics while keeping useful context, outcomes, and failures visible.

This slice is source/offline preparation only, based on
`a55f79c63e45fd0f141ffb2cd43eea5cad3522f0`. The active production sync must remain
untouched. No backend, cloud, directory, or live-state access is authorized.
State consolidation and activation require separate operator approval after
all writers have stopped.

## Checklist

- [x] Read repository guidance and confirm the clean current-main baseline.
- [x] Trace settings and file-generation dependencies before Terraform.
- [x] Wire the unified root and preserve authentication and permission guards.
- [x] Add an explicit cutover gate and remove the split provisioning stage.
- [x] Prove the proposed state transfer with native local-only synthetic states.
- [x] Cover fresh, split, legacy, partial, and rejected ownership cases.
- [x] Remove and ignore the nested repository template without recreation.
- [x] Correct matrix context and fold native Terraform, discovery, file, and project logs.
- [x] Update the existing directly related documentation.
- [x] Run focused controls and the ordinary development gate.
- [x] Prepare the draft description and concrete operator approval procedure.

## Validation

- `.\build.ps1 test-tenant-terraform`: 21 ordinary-root cases and 15 Azure-child
  cases passed. Includes a real mocked-provider single apply publishing its
  own identity client ID, native template-state preservation, and seven
  unchanged old-tenant forget actions with no refresh/read/destroy.
- `.\build.ps1 integration -TestName 'Integration: local repository state consolidation*'`:
  four native local-only cases passed with Terraform 1.16.4. Whole-module moves
  preserve IDs, provider bindings, private data, sensitive paths, root outputs,
  and separate lineages. Tests cover legacy dependencies, destination
  collision refusal, source-first cutover, and stale/foreign push rejection.
  The final inspector was rerun against these native transfers.
- Focused unit and component controls cover the actual matrix action, driver
  ordering, approval and WhatIf boundaries, saved-plan rejection, secret-safe
  output, project failures, and read-only staged-state inspection.
- Full `.\build.ps1 pre-commit` passed layout, lint, 2,897 unit tests and
  1,289 component tests (nine unit and one component platform-dependent skips).
  The final gate includes immutable GitHub-ID/cached-name coverage and both
  legacy/desired membership ownership collision controls.

## Blockers or dependencies

No live state inventory or approved writer freeze was performed. The existing
production run was left untouched; its status is the coordinator's concern.
Do not claim a finalized live migration inventory or execution readiness.
The proposed cutover uses native state moves on working copies, followed by
separately approved source-first publication under a complete writer freeze.
The coordinator has the proposal; no backend-writing migration tool was added.
The local inspector is read-only and requires original hashes and a frozen
identity record. Native moves retain outputs in the source and clear affected
dependency caches; native local push also advances serial again. Actual backend
persistence/provenance, incomplete or missing states, maintenance authentication,
and all publication/resumption decisions remain operator work.
