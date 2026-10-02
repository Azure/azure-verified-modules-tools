# Bicep deployment and cleanup workflow parity

**Status**: in-progress
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-didactic-memory`

## Outcome

Reimplement the existing registry deployment and cleanup behavior in
Avm.Authoring without reducing supported functionality. The runner owns
ordinary cleanup; the reaper remains a fallback. A local temporary JSON
file may retain cleanup state, and a GitHub Actions caller may upload that
file as an artifact. Neither a new storage service nor an expanded
subscription or management-group reaper is a prerequisite.

The user explicitly replaced the previous recovery prerequisite and
confirmed that every existing supported scenario is required. Restricted
resource allowlists, simplified fixtures, skipped assertions, and absent
cleanup handlers cannot be reported as complete workflow parity.

Implementation baseline:

- Tools main: `b0ba22f2fca81e4e068414e7f20bb703acd37de4`,
  advanced from `c724bcaf967308b14fbd3a9975cbb015d29e8719` after
  [tools #217](https://github.com/Azure/azure-verified-modules-tools/pull/217)
  merged.
- Registry workflows and utilities:
  `89b1910d5d11e4f87579ae98e119effe9b7c9578`.
- Preserve the existing registry runner and workflows during implementation.

## Checklist

- [ ] Map deployment inputs, scopes, token handling, retries, subscription
      selection, assertions, outputs, and cancellation behavior.
- [ ] Match recursive deployment-operation discovery, including partial
      results and preflight-rejected deployment attempts.
- [ ] Match lock removal, dependency ordering, resource-specific deletion,
      post-removal processing, and cleanup error reporting.
- [ ] Remove functionality gaps in the new runner without replacing target
      verification with broad subscription or management-group deletion.
- [ ] Retain minimal, non-secret local cleanup state where required; make
      its location usable by a caller's artifact-upload step.
- [ ] Exercise unmodified registry cases and failure paths with explicitly
      labeled offline coverage.
- [ ] Update the directly related command help and migration contract.
- [ ] Run focused checks and the ordinary full development gate.
- [ ] Commit, push, and open the implementation change for review.

## Validation

The [native cleanup foundation](2026-10-02-bicep-native-cleanup-foundation.md)
passed 72 focused offline unit controls and the ordinary full development
gate on the updated main baseline: 2,606 unit tests and 1,261 component tests
passed, with nine unit skips and one component skip. The controls cover
native handler behavior, exact resource identification, dependency
ordering, recursive Create-operation discovery, pagination, partial lookup
results, preflight rejection, cancellation, and checked CLI failures.

The adapted helpers are not yet wired into the e2e runner. They do not
change its current restrictions or constitute full workflow parity. State
persistence, authentication preflight, execution retries, region selection,
subscription selection, and runner integration remain in progress.

Reference source was read from immutable Git objects already present
locally. No Azure deployment, deletion, permission change, reaper execution,
release, or registry workflow change has been performed.

Offline tests are not proof of live Azure parity. Registry CI replacement
remains separate from implementation and requires approved live
qualification of the existing supported behavior.

## Blockers or dependencies

The scaffold-description dependency is resolved by the merged
[tools #217](https://github.com/Azure/azure-verified-modules-tools/pull/217).
Its existing package qualification was not duplicated. No new distribution
has been published.

An Actions artifact is recoverable only after its upload completes. Runner
loss before upload still relies on the reaper or operator cleanup, matching
the accepted fallback model rather than requiring an external journal.
