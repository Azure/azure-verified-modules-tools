# Bicep BAMI-only publisher

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `pr/211/jaredfholgate-bicep-half-library-proposal`

## Outcome

Replace the held half-library proposal in
[#211](https://github.com/Azure/azure-verified-modules-tools/pull/211) with
five-field BAMI execution-variable publication, without a module selector.
Validate all eight source fields and refuse routine retargeting of any present
execution value. Initialize missing values only when all present values match.
Preserve per-write drift checks, bounded GET visibility settling, complete and
final readback, explicit failure reporting, and plan/ShouldProcess behavior.

## Checklist

- [x] Verify the existing draft head and merge current Tools main normally.
- [x] Remove obsolete Bicep selector configuration, converters, and publication.
- [x] Replace selector tests with initialization and retarget-refusal coverage.
- [x] Run focused build gates and verify protected surfaces remain unchanged.
- [x] Prepare the source-only commit for the existing held draft.

## Validation

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

## Blockers or dependencies

The Bicep consumer change must be reviewed and merged first. Keep this draft
unmerged; the parent owns live cutover and eventual one-shot removal of the
retired consumer variable after old writers drain. No live variable deletion,
deployment sweep, workflow dispatch, Azure query, identity/state changes, or
Terraform/managed-file ring changes are included. Team documentation belongs
in the parent's existing Azure-Verified-Modules-Docs review.
