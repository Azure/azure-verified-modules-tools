# Bicep BAMI-only publisher

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `pr/211/jaredfholgate-bicep-half-library-proposal`

## Outcome

Replace the held half-library proposal in
[#211](https://github.com/Azure/azure-verified-modules-tools/pull/211) with
five-field generic execution-variable publication to
`Azure/bicep-registry-modules`, without a module selector.
Map the validated BAMI execution projection locally to `VALIDATE_TENANT_ID`,
`VALIDATE_CLIENT_ID`, `VALIDATE_SUBSCRIPTION_IDS`, `VALIDATE_MANAGEMENT_GROUP_ID`,
and `VALIDATE_PERSISTENT_SUBSCRIPTION_ID`. Keep the eight-field source bundle
and Terraform settings unchanged. Old BAMI aliases, the retired selector, and
customer legacy keys remain unmanaged. No Secrets writes, migration bypass,
or live operation.
Validate all eight source fields and refuse routine retargeting of any present
execution value. Initialize missing values only when all present values match.
Preserve per-write drift checks, bounded GET visibility settling, complete and
final readback, explicit failure reporting, and plan/ShouldProcess behavior.
External contributor credential, subscription-pool, and Key Vault configuration
remains unchanged, including the Key Vault capability and deprecation warning.
Consumer bindings are maintained separately: generic Variables before Secrets,
with legacy pool/singleton/management-group aliases retained and no repository
or provider mode check. Independent `CI_` Secrets/Variables/Key Vault precedence
is unchanged.

## Checklist

- [x] Verify the existing draft head and merge current Tools main normally.
- [x] Remove obsolete Bicep selector configuration, converters, and publication.
- [x] Replace selector tests with initialization and retarget-refusal coverage.
- [x] Run focused build gates and verify protected surfaces remain unchanged.
- [x] Prepare the source-only commit for the existing held draft.
- [x] Map only target names to generic Variables and test exact source mapping.
- [x] Verify old aliases and legacy values remain unmanaged and unwritten.
- [x] Preserve shared validation, Terraform, workflows, and governance blobs.
- [x] Document coordinated publisher-first migration without live execution.

## Validation

### Generic target follow-up

Baseline: `fc4c3560df8c3b2f3161aa05f21fe73bad7c4db3`.
The same focused pre-commit command below passed layout/lint, 226 unit tests,
and 18 component tests, with zero failures or skips. Source-to-target mapping,
all five generic retarget guards, old-alias/legacy write rejection, snapshots,
and byte-preserving unmanaged-record assertions use synthetic fixtures only.
Initial fixture failures were corrected by distinguishing source and target
keys and avoiding JSON date conversion in preservation assertions; no
production safeguards were relaxed.

Only the two publisher libraries, their unit/component tests, README, and
this record change from the baseline. All other tracked file blobs remain
unchanged, including the entry point, eight-field validator and its tests,
Terraform settings/state/candidate guards, all workflows, managed-file
governance, and historical half-library record. Namespace, UTF-8/LF, parse,
and diff-whitespace checks passed.

### Earlier BAMI-only implementation and scope clarification

Initial head: `1b729b59da832c80d394c1536c3a6706c01c30f8`.
Merged Tools main: `0e9e166204071a9d12cd4796dcfc96713c8e2225`.
Focused pre-commit passed: layout, lint, 209 unit tests, and 18 component tests;
zero failures or skips. Tests use synthetic data and mocked APIs only.

```powershell
.\build.ps1 pre-commit -TestName @(
    'Central test tenant group resolution*', 'Complete BAMI input bundle*',
    'Guarded nonsecret Bicep variable publication*', 'Narrow GitHub nonsecret variable adapter*',
    'Bicep variable adapter uses Invoke-AvmProcess*', 'Bicep workflow isolation*',
    'Bicep test tenant entry point*', 'Bicep variable readback*',
    'Tools repository federation context*', 'Terraform test tenant selection*',
    'Candidate plan and output safety*', 'Terraform effective contract and state wiring*',
    'State identity wiring*', 'Resolve-RepositorySyncStateConfiguration*',
    'State backend workflow resolution*', 'Resolve-RepositorySyncStateIdentity*'
)
```

Coverage includes five-field no-change and initialization, complete/partial
tuple retarget refusal, malformed bundles/pools, retired-selector/arbitrary-write
rejection, ShouldProcess, lost acknowledgements, GET failures, bounded visibility
settling, outside/metadata drift, complete/final readback, and no rollback.
Existing Terraform default, state/candidate, and shared managed-file group
tests remain in the focused gate.

An additional committed-head rerun exposed an unordered-hashtable JSON
expectation in the lost-acknowledgement component test. The assertion now
compares all 28 entries in the publisher's canonical property order, retaining
exact value and failure checks. The existing analyzer transient-retry path
also ran successfully; no analyzer or publisher retries were added.

Source-reference, UTF-8/LF, PowerShell parse, and diff-whitespace checks passed.
The Bicep publishing workflow, Terraform config/state/backend, managed-file
governance, generic group resolver, labels, and authoring module are unchanged
from merged main. Only the obsolete config-test path filter changed in workflows.

The documentation-only scope clarification changes this record and the
repository-management README. Diff-whitespace and UTF-8/LF checks passed;
all other file blobs, including runtime code, tests, workflows, and the
historical half-library record, are unchanged from
`a5cc25c18a457dbefcb72d3da9aa7a6776ee49ad`. No runtime tests were rerun for
this documentation-only follow-up.

## Blockers or dependencies

Keep this draft unmerged pending coordinated migration approval. The generic
namespace supersedes the earlier consumer-first ordering: merge and publish
the generic-variable publisher first to stage and verify all five Variables,
then switch consumers, then drain old code before separately authorized
cleanup. The parent owns live preflight, publication, and obsolete-name
retirement; none is authorized by this source-only slice. No live variable deletion,
deployment sweep, workflow dispatch, Azure query, identity/state changes, or
Terraform/managed-file ring changes are included. Team documentation belongs
in the parent's existing Azure-Verified-Modules-Docs review.
