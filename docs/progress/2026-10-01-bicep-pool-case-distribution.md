# Bicep test-pool case distribution

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Give the offline BAMI test-pool selector one random seed per run and a
zero-based case index. The same seed must yield the same permutation for
every case, and indexing modulo the 28 validated subscriptions must spread
the first 28 cases without reuse. This preserves the current registry
matrix's shared-shuffle and case-index behavior without inheriting its
global random state or changing registry workflows. The pinned registry
workflow generates one seed for the matrix; its deployment action shuffles
once per job with that shared seed and uses `job-index % pool-size`.

Retain exact pool-shape, tenant and protected-subscription validation.
Generate seed entropy locally, but do not wire selection into deployment,
change cloud settings or infer target authorization from a pool entry.

## Checklist

- [x] Compare the pinned registry shared-seed and matrix-index contract.
- [x] Implement a deterministic cross-platform permutation from one
      cryptographically generated per-run seed.
- [x] Prove case spread, deterministic replay, wraparound and invalid-input
      refusal with offline tests.
- [x] Run targeted tests, full pre-commit gate and coverage; commit and push
      on the existing review.

## Validation

- Pinned registry `main@74a906828e3e42f6c8fed17f7323e999c78cbf78`
  generates one seed for its deployment matrix, shuffles the subscription
  list with that seed in each job, and selects `job-index % pool-size`.
- Focused `./build.ps1 test -TestName '*Bicep BAMI test subscription pool selection*'`:
  38 passed, zero failed. Repeated calls with the same seed select all 28
  unique subscriptions before wraparound, independent of pool ordering;
  invalid seeds, negative indexes and malformed/protected pools are refused.
- `./build.ps1 pre-commit`: layout/lint passed; 2,111 unit tests passed,
  nine skipped, and 1,046 component tests passed. The 49 nonfatal
  test-generated warnings came from unrelated mocked repository-management
  cases.
- `./build.ps1 coverage`: 72.56% (6,019 of 8,295 commands), above the 70%
  floor; 2,111 unit tests passed and nine were skipped.
- New source files are LF UTF-8 without BOM; no cloud, MCR, reaper,
  workflow, permission or registry source was changed.

## Blockers or dependencies

The future runner must create one seed and share it across cases or workers;
generating a new seed per case would destroy the batch distribution.
Selection remains candidate-only until test-management-group membership,
Admin/Persistent exclusion against trusted configuration, durable recovery
and safe owned cleanup are proven. No live Azure or MCR activity is part of
this slice.

The existing BAMI reaper is an eventual aged-resource-group backstop, not
per-case owned cleanup: it does not check run tags or group contents and does
not recover higher-scope resources. Two future options require a user
decision:

- Adapt the separate BAMI runbook to recognize run tags, reconcile current
  children with retained ownership evidence, quarantine any ambiguity and
  alert instead of deleting. This still cannot recover non-RG objects and
  would require a reviewed BAMI code and cloud runbook update.
- Provide a durable pre-Create receipt and a recovery actor for RG and
  higher-scope deployments. It would record exact targets and preview IDs,
  claim work conditionally after a crash, inspect operations and live
  ownership, and quarantine unknown objects. This requires approval for a
  suitable existing or new durable store, its access and a scheduled actor.

Neither option has been approved or implemented here. Deployment history
can be pruned, so it is not a proven substitute for a pre-Create record.
