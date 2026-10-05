# Simplify temporary state migration checks

**Status**: complete
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-simplify-migration-checks`

## Outcome

Removed the temporary repository-state migration's unnecessary comparison of
Terraform-generated `check_results`. Staging and publication/recovery now share
one small metadata comparison that also excludes writer-version metadata.
Resource contents, provider and private data, root outputs, state schema,
lineage and native serial increments remain checked. Backend/repository scope,
duplicate ownership, stale-write checks, source-first locked publication and
private recovery backups are unchanged. No settings, cleanup, production reads
or live migration were added or performed.

Baseline: current `main` at `9c9ade0e6b4ae0acc2ec30bc90758c7c83171cad`.
The reported [apply-mode failure](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37336287157/job/111859242679)
occurred during local staging after the native module move, before publication.
The driver stages the entire inventory before entering its publication phase;
this confirms the failure path precedes remote writes, not the live backend's
current contents.

## Checklist

- [x] Read repository guidance, inspect current main and check existing reviews.
- [x] Trace staging, snapshot comparison, publication and recovery.
- [x] Reproduce the failure with managed Terraform 1.15.8 and nonempty generated checks.
- [x] Remove the unnecessary shared metadata checks without weakening resource safeguards.
- [x] Exercise native local-backend publication, unified plan/apply, completed reruns and recovery.
- [x] Cover changed resources, provider/private data, lost outputs, collisions and stale state.
- [x] Run targeted tests and the required repository gate.

## Validation

- Reproduced the original `Snapshot field check_results changed unexpectedly`
  exception through `New-RepositoryMigrationTransfer` before the source fix,
  immediately after its successful native module move.
- Used `Resolve-AvmTool`'s managed Terraform 1.15.8. Real local configurations
  generated variable validation, resource postcondition, output precondition and
  `check` results. Native state writes reordered these results; tests do not
  assume deterministic ordering or require cached results to survive.
- Ran `.\build.ps1 -Tasks @('integration', 'component') -TestName
  @('Integration: *repository state*', 'Repository state transfer local
  inspection*', 'Repository migration*')`: **16 integration and 208 component
  tests passed**, with no failures or skips.
- Ran `.\build.ps1 pre-commit` with no `AVM_OFFLINE` override: layout and lint
  passed; **2,897 unit tests passed (9 skipped)** and **1,469 component tests
  passed (1 skipped)**, with no failures. The existing analyzer-engine retry
  recovered its transient exception; the gate finished successfully in 13m08s.
- The real stager, driver and source-first publisher ran against local backends
  with synthetic Azure/GitHub ownership and opaque private-state fixtures.
  Existing component tests retained private backup, ETag, create-only upload,
  hash-readback, backend-scope and resource-ownership negative controls.
- A complementary providerless native lifecycle used the real publisher and an
  ordinary unified saved plan/apply. All **four resources were no-op** in the
  first plan: no creates or destroys. Resource IDs and the existing root output
  survived; apply recomputed all four check kinds at the new module addresses.
  Completed reruns accepted subsequent ordinary state evolution without pushing
  old images.
- Source and destination lost-response recovery tolerated changed/reordered
  cached results without repeating pushes. Stale source/destination snapshots,
  changed resources/private/provider data, lost outputs, collisions and changed
  critical metadata still rejected.
- `git diff --check` passed. Exact-head automatic hosted results belong with the
  published source review, not a follow-up evidence-only commit.

## Blockers or dependencies

The native tests are local synthetic exercises, not live Azure/GitHub provider
applies. Live migration and subsequent ordinary synchronization remain
user-started operations after review and merge. This is a source correction,
not evidence of live migration success; cleanup remains deferred.
