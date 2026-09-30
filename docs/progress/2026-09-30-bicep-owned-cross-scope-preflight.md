# Bicep run-owned resource-group preflight

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Stage subscription-scoped Bicep examples that create a resource group and
deploy an inline module into that exact group without editing registry
source. Require an ownership tag in the resource-group Create payload,
inspect the nested resource and target shapes, and refuse unsupported effects
before Azure access. Exercise what-if, operation and teardown safeguards
offline with mocks; do not enable a cross-scope Create without recoverable
ownership and cleanup.

## Target and recovery boundary

The intended replacement runner will randomly select from the configured
BAMI **test-only** subscription pool and verify its tenant. It will not
provision or reserve a dedicated subscription or share a lease with legacy
CI. Each concurrent run must have a unique deployment name and owned
resource-group tag; selecting a shared pool member alone proves no resource
ownership. Persistent deployment operations and group tags must support
recovery across runner loss, with ambiguous resources quarantined rather
than deleted. Local temporary files alone are not durable recovery.
Admin/Persistent subscriptions, baseline management groups and identities
remain outside the runner's lifecycle.

## Checklist

- [x] Pin and inspect a real cross-resource-group example compiled with
      Bicep offline; identify conditional and unsupported effects.
- [x] Stage tags only in a temporary compiled ARM payload and require one
      run-owned new group with a same-subscription inline group deployment.
- [x] Verify exact what-if identities, nested operations, resource types,
      ownership and empty-group teardown with mocked success/failure cases.
- [x] Refuse runtime Create for any path without crash recovery or verified
      owned cleanup, and document what remains unsupported.
- [x] Run the full local gate and coverage, then commit and push on the
      existing review.

## Offline proof and remaining runtime boundary

Pinned public source:
[`Azure/bicep-registry-modules@6eb8e6ff3fe2910043d184da4192799752271ecf`](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff3fe2910043d184da4192799752271ecf/avm/res/network/route-table/tests/e2e/defaults/main.test.bicep).
The committed fixture is that source compiled with local Bicep
`0.47.16.16243` without restore. Its group has no tag; the compiled
subscription template contains one group and one inline, group-scoped ARM
deployment with ARM 2.0 symbolic resources. The original inline template
also includes conditional locks and role assignments, so the **real
example is rejected**. Tests explicitly remove those entries from an
in-memory copy to exercise only the unprivileged route-table shape; the
source and pinned fixture remain unchanged.

The offline proof permits one new run-suffixed group with an exact literal
run tag and one inline group deployment with a direct dependency on that
group. A custom `namePrefix` is preserved, but the resolved group and
resource names must still contain the generated run suffix. Full-payload
what-if must expand each nested inline template and predict only exact
`Create` IDs at the selected subscription and that group. It rejects
`Ignore`, `Deploy`, `NoChange`, `Modify`, `Delete`, other subscriptions,
groups or types, malformed targets, case-variant ownership tags, linked
templates and unreviewed parameters. Mocked teardown requires terminal
deployment history, matching subscription and group operation IDs, resource
types and names, the live ownership tag, and an empty group after deleting
individually verified children. An unknown group member remains
`CleanupPending` and blocks group deletion. These helpers do **not** enable
cross-group Create; the e2e runner refuses it before any Azure call.

This proof does not make any of the 902 unignored pinned higher-scope
examples deployable. It covers neither the original route-table example's
authorization effects nor the 739 authored idempotency repeats. Other
resource families, existing-group updates, multiple or foreign groups,
aliases, scripts, subscriptions created as resources, management-group and
tenant cross-scope effects, tenant-root permissions, and baseline BAMI
management-group/identity lifecycle remain outside the allowlist. The
public command still takes an explicit `-SubscriptionId`; random selection
from the verified BAMI test-only pool has not been wired.

## Concurrent runs and interrupted-job recovery

A replacement runner can select a random member of a separately verified
test-only subscription pool after checking tenant and account identity.
Admin/Persistent subscriptions must not be eligible. Each of its own
concurrent cases needs a distinct full run ID, deployment name and tag-at-
create group; no lease with the old workflow is required for cutover. A
durable record must bind run ID, tenant, selected subscription, target group,
root/nested deployment IDs, approved what-if IDs/types, and cleanup state
**before Create**. A recovery worker needs scoped access and a way to
enumerate incomplete records across all pool members after runner loss.
It must recheck deployment operations, current group tags, child IDs/types
and group contents before deleting anything. Missing history, foreign
contents or contradictory ownership must remain `CleanupPending`; a tag
alone cannot authorize deletion. The record store, recovery actor,
atomic claim/retention policy and final checks against concurrent foreign
writes still need agreement and implementation. Temporary files and
best-effort `finally` cannot substitute for that record. No persistent
BAMI baseline group, subscription, identity or role is created or altered.

## Validation

The focused build selected and passed 53 unit tests; the fake-runner
component build selected and passed 5 tests. `./build.ps1 pre-commit` passed
layout, lint, 2,043 unit tests (9 skipped), and 1,025 component tests.
`./build.ps1 coverage` passed at 73.43% (5,782 of 7,874 commands; 70% floor).
The new source file was normalized to required LF before the final gate.
Only pinned public-source compilation with `bicep --no-restore` and local
mocks were run; no Azure, MCR, registry CI or selector changes were made.

## Blockers or dependencies

The earlier dedicated-subscription isolation proposal is superseded by the
configured test-only pool and per-run tagged resource groups. This slice
does not authorize live deployment or claim registry CI parity; broader
resource types, idempotency repeats and durable recovery need separate
proof before a real Create can be enabled. Whether nested deployment
history appears in the group's resource inventory also needs a real
read-only characterization: this proof leaves any nonempty group for
manual reconciliation, not bulk deletion. The existing direct resource-
group runner still has its earlier tag-checked whole-group teardown and
needs separate foreign-child hardening before full CI cutover.
