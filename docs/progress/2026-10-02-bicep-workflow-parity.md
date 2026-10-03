# Bicep deployment and cleanup workflow parity

**Status**: in-progress
**Started**: 2026-10-02
**Updated**: 2026-10-03
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

- [x] Map deployment inputs, scopes, token handling, retries, subscription
      selection, assertions, outputs, and cancellation behavior.
- [x] Match recursive deployment-operation discovery, including partial
      results and preflight-rejected deployment attempts.
- [x] Match lock removal, dependency ordering, resource-specific deletion,
      post-removal processing, and cleanup error reporting.
- [x] Remove functionality gaps in the new runner without replacing target
      verification with broad subscription or management-group deletion.
- [x] Retain minimal, non-secret local cleanup state where required; make
      its location usable by a caller's artifact-upload step.
- [x] Exercise unmodified registry cases and failure paths with explicitly
      labeled offline coverage.
- [x] Update the directly related command help and migration contract.
- [x] Run focused checks and the ordinary full development gate.
- [x] Commit and push the implementation to the existing draft review.
- [x] Qualify an unsigned extracted distribution through native contracts
      and unmodified registry cases without live Azure.
- [x] Confirm hosted checks, including coverage, for the package correction.
- [ ] Qualify the native dependency import-scope correction before the
      approved live smoke.
- [ ] Complete separately approved release and live Azure qualification
      before replacing registry workflows.

## Validation

The [native cleanup foundation](2026-10-02-bicep-native-cleanup-foundation.md)
passed 72 focused offline unit controls and the ordinary full development
gate on the updated main baseline: 2,606 unit tests and 1,261 component tests
passed, with nine unit skips and one component skip. The controls cover
native handler behavior, exact resource identification, dependency
ordering, recursive Create-operation discovery, pagination, partial lookup
results, preflight rejection, cancellation, and checked CLI failures.

The [cleanup state and context slice](2026-10-02-bicep-cleanup-state-context.md)
adds private dependency/authentication preflight, process-scoped context
restoration, ordered cleanup retries and atomic non-secret state. Its full
development gate passed 2,646 unit tests and 1,293 component tests, with
nine unit skips and one component skip. Both slices are retained in draft
[tools #219](https://github.com/Azure/azure-verified-modules-tools/pull/219).

The [native execution input slice](2026-10-02-bicep-native-execution-inputs.md)
adds typed CI inputs, native deployment helpers, bounded retries,
same-process assertion/hook support and public `avm test cleanup` recovery.
Its ordinary full gate passed 2,710 unit controls and 1,315 component
controls, with nine unit skips and one component skip. Those committed
helpers did not yet change the e2e runner's restrictions.

The [runner integration](2026-10-02-bicep-workflow-runner-integration.md)
is locally implemented and qualified against unmodified registry source
with simulated Azure operations. It records owned groups and attempted
deployment IDs before submission, retains state outside temporary
templates/parameters, preserves assertions then post-hook then cleanup,
and connects execution
retries, region selection, subscription-pool selection and typed CI
parameter handling. Hosted completion permits caller-owned sign-in
renewal without a credential bridge.

Exact provider-container expansion, ownership rechecks, cross-subscription
cleanup, cancellation recovery and hosted completion have focused controls.
Six real offline compiler scenarios cover complete subscription-to-group,
management-group and tenant templates, including authored repeated
deployments. The unmodified PostgreSQL Pester suite passes correct responses
and rejects a deliberately incorrect response without preventing cleanup.
All 5,611 snapshot files retain their bytes. These are real source/compiler
and assertion results, not live Azure deployment evidence.

Runtime
parameter and token maps now preserve authored `keys` and `count` names,
with file-backed controls complementing the README behavior from
[Azure/bicep-registry-modules#7442](https://github.com/Azure/bicep-registry-modules/pull/7442).
Qualification also corrected JSON scalar preservation and SDK-style
`Value` access in assertion inputs. The old restrictive engine is removed;
native target checks, exact attempted IDs and recoverable cleanup remain.

The integrated source passed the ordinary full gate: 2,750 unit tests and
1,257 component tests, with nine unit skips and one component skip; layout
and lint passed.

The [native package qualification](2026-10-02-bicep-native-package-qualification.md)
passed with 348 byte-verified payload files, 56 extracted command definitions,
158 packaged unit tests, 143 packaged component tests, five real scaffold
compiles and six real-compiler registry scenarios with simulated Azure.
It exposed and corrected propagation of the explicit version-check override
through the public e2e command. The artifact records the exact source
boundary rather than claiming unchanged-main provenance.

Additional lifecycle/input controls address the prior hosted coverage
shortfall. The corrected source passed the ordinary full gate with 2,807
unit tests and 1,257 component tests, with nine unit skips and one component
skip; local coverage reached 73.18% against the unchanged 70% floor.
Hosted verification and approved live Azure qualification remain separate.

The [hosted qualification follow-up](2026-10-03-bicep-hosted-qualification.md)
confirmed passing hosted coverage on all three operating systems, but
identified a real lint warning and a Windows job timeout. It corrects the
callback-only switch reference and applies the user-approved 25-minute
test-job ceiling. Its refreshed unsigned package and ordinary local gate
passed; all 17 hosted checks subsequently passed for `9234c88`.
One bounded live route-table smoke is approved. Before sign-in, its setup
exposed a separate [dependency import-scope issue](2026-10-03-bicep-azure-dependency-scope.md).
Only the selected Accounts module now becomes globally visible in the current
process; other imports and version/provenance checks retain their behavior.
The isolated regression, real local prerequisites and refreshed package
qualification pass. The ordinary gate passed 2,814 unit and 1,259 component
tests, with nine unit skips and one component skip. Hosted qualification of
the new bytes is still pending.

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
