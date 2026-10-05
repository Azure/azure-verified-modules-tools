# Complete repository migration preflight

**Status**: complete
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-complete-migration-preflight`

## Outcome

Correct the one-off repository-state migration using a complete, approved
read-only inventory and native local rehearsal, rather than another isolated
destination whitelist exception. The baseline is Tools main
`f76e852c8f11d6fa0634457c725073704c8f0c31`; the
[failed run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37353997227)
stopped during local preparation after 25 moves, before remote publication.

## Checklist

- [x] Read repository guidance and confirm the clean, current-main worktree.
- [x] Snapshot every in-scope ordinary, former and recovery entry into private
      originals, with exact-name paths, hashes and storage metadata.
- [x] Rehearse every required native move with managed Terraform 1.15.8 on
      isolated local copies and collect all blockers.
- [x] Remove unnecessary compatibility restrictions while preserving ownership,
      collision, stale-write and recovery checks.
- [x] Repeat the full rehearsal against the untouched originals.
- [x] Add sanitized regression shapes and exercise native local publication,
      ordinary convergence, completed reruns and recovery.
- [x] Run focused component and native integration checks.
- [x] Run the required complete local gate.

The corrective review records post-commit publication and exact-head automatic
CI. No migration workflow is dispatched by this slice.

## Inventory and correction

The approved snapshot contains 491 objects: 262 ordinary states, 229 former
BAMI states and no recovery records. Every object was downloaded once with
its listed ETag as a read precondition. Originals are read-only, hash-verified
and separated from local working copies; exact-name hashes keep the two
case-distinct OpenShift blobs separate on Windows.

The baseline rehearsed all 229 native module moves, covering 1,603 resource
blocks and 2,521 instances. Full-inventory inspection also found:

- Seven flat legacy module roots without former BAMI sources, including
  variants with optional teams and without labels/rulesets.
- Twelve unavailable GitHub lookups and five renamed repositories with the
  same immutable IDs, all without former BAMI sources.
- Four pre-existing GitHub object overlaps between old and current ordinary
  states. None involves a moved or existing BAMI owner.

The correction audits flat roots by recorded repository and retired-tenant
ownership, without adding repository-name exceptions. It preserves other
destination namespaces, resource types and provider aliases by full comparison.
Independent GitHub lookup remains mandatory for transfers and existing BAMI
ownership, not unchanged ordinary history.

Nonmoving overlaps are reported and preserved, not repaired or silently dropped.
Any overlap involving a former source or existing BAMI target still blocks in
either inventory order, including the same scoped ARM or membership ID represented
through different provider resource types. Missing BAMI ownership remains a blocker at root,
nested or retired addresses. Backend identity, frozen hashes, source-first locked
publication, private create-only backups, checkpoints and completed-rerun checks
are unchanged.

## Validation

The final exact-inventory rehearsal passed at 20:36:56 UTC on 2026-10-05:
491 snapshots inspected, 229 native transfers prepared, 33 ordinary states
audited unchanged, zero blockers. All original hashes and runtime-source hashes
remained unchanged. Resource/provider/private/output preservation, exact moved
namespace, root lineage and native serial increments passed for every transfer.
There were no remote writes, lock changes or provider queries.
This final replay includes the cross-provider collision comparison. Its 458
staged source/destination images also match the earlier corrected replay in
every JSON value except recomputable cached `check_results`.

The focused native integration suite passed all 18 tests without skips. Its
ordinary saved plan contains six no-op resources, including unchanged root and
nested resources, and no unexpected creates or deletes. Publication recovery,
completed reruns and later ordinary permission retirement also passed.
The final focused component run passed all 235 tests without skips, including
missing-owner and cross-provider collision regressions. Two parallel full-gate
runs passed layout, lint, 2,897 unit tests and every migration component test,
but different unrelated module-catalog temporary-directory renames returned
access denied. The first failing test passed unchanged in isolation. The
complete unfiltered `.\build.ps1 pre-commit` gate then passed with the existing
`AVM_COMPONENT_SHARD_COUNT=1` option: layout, lint, 2,897 unit tests and 1,496
component tests passed; the existing 9 unit and 1 component skips remained.
No source, test or machine-protection changes were made for those filesystem
errors. All four runtime source hashes still match the successful final rehearsal.

The real-snapshot harness runs the production inventory action and native
Terraform 1.15.8, with frozen public repository metadata and local read adapters.
Backend initialization and all Azure/write adapters fail closed. It permits only
the explicit local `state mv`, checks every original hash again, and records
source-file hashes to detect implementation changes during the rehearsal.
It does not simulate workflow/OIDC context or relax production trust guards.

Live state bytes and private attributes remain outside the worktree and are not
test fixtures, committed evidence or uploaded artifacts. Regressions use fake
IDs/values and local backends. Ordinary plan/apply uses Terraform's built-in
provider; publication/recovery retains synthetic Azure/GitHub state shapes
without querying those services.

## Blockers or dependencies

Only the user-approved reads from the existing repository-sync container and
local staging are authorized. This slice must not write remote backups or
checkpoints, push or delete remote state, change locks or credentials, query
providers, control workflows, merge, or begin migration cleanup.
The parent owns internal team documentation and any user-controlled live run.
