# Source-only Bicep BAMI batch draft

**Status**: blocked
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bami-bicep-rollout-batch`

## Outcome

Prepared exactly three additions to the existing Bicep canary group, preserving
every previously selected path, group precedence, and the `legacy` default.
[Configuration](../../repository-management/bicep-test-tenant-config/config.json)
remains the only current cohort definition; no README roster or membership
assertions are added to tests.

This is a source-only draft, not runtime qualification or rollout approval.
The Bicep publisher is active: merging this configuration can route the three
added paths to BAMI at the next scheduled or manual publication. The review
must remain draft and unmerged until the parent verifies the two-clean-run
and current-cohort gates, reviews this candidate batch, and obtains explicit
live activation/testing approval. The full-rollout goal does not waive
per-batch or costly-scenario gates. Lab remains selected and unresolved;
retaining its selection does not authorize running it.

## Checklist

- [x] Read repository guidance and check related reviews and branches.
- [x] Confirm no overlapping open Bicep cohort review exists.
- [x] Add only the three requested canonical paths in sorted order.
- [x] Compare the actual before/after configuration with the existing resolver.
- [x] Run the existing focused configuration and publication gates.
- [x] Confirm all files outside this configuration and progress record are unchanged.

## Validation

Baseline: Tools `main` at `1975550a6693a3c5817d80f8359c1a9370733fcd`.

```powershell
.\build.ps1 pre-commit -TestName @(
    'Central test tenant group resolution*'
    'Tools-owned Bicep configuration*'
    'Complete BAMI input bundle*'
    'Bicep module-path array validation*'
    'Guarded nonsecret Bicep variable publication*'
    'Narrow GitHub nonsecret variable adapter*'
    'Bicep variable adapter uses Invoke-AvmProcess*'
    'Bicep workflow isolation*'
    'Bicep test tenant entry point*'
    'Bicep variable readback*'
)
```

Passed: layout, lint, 155 unit tests, and 17 component tests; zero failures or
skips. Publication tests use mocked GitHub calls and local process fixtures,
not live services. No dependencies or tests were added.

A one-time local check passed the actual baseline and edited configurations
through `ConvertTo-AvmBicepModulePaths`: four selected paths become seven,
with exactly the three requested additions and no removals. Every previous
selection is preserved; the default and synthetic unselected paths still
resolve to `legacy`. Removing only the additions from an in-memory copy
reproduces the entire baseline configuration. Canonical paths remain sorted.

`git diff --check` passed. The diff against the baseline is empty outside
this configuration and progress record, including all workflows, shared
resolvers, publisher code, Terraform configuration, identity, repository-sync,
and backend files. The README and all tests are unchanged.

## Blockers or dependencies

Source preparation is complete. Live activation/testing approval is blocked
pending the parent's qualification gates and candidate review. None of the
three additions has been qualified in BAMI. Provider, region, permission, and
cost readiness require separately approved runtime evidence.

No live selector writes, workflow dispatch/apply/retry/cancel/approval, cloud
queries or deployments, settings/identity/role/secret/provider changes, or
cleanup/state operations were performed. No labels, merge, or auto-merge
actions were performed or authorized by this source-only slice.
