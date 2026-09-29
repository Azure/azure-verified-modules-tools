# Fast Bicep canaries

**Status**: complete
**Started**: 2026-09-29
**Updated**: 2026-09-29
**Branch**: `jaredfholgate-fast-bicep-canaries`

## Outcome

Extend the central Bicep `testTenant` canary group while preserving its existing
selection and the legacy default. The current paths are maintained only in
[configuration](../../repository-management/bicep-test-tenant-config/config.json).
The eight-source/five-execution bundle, identities, Terraform selections, and
managed-file rings remain unchanged.

This is source-only preparation. Merging the selection makes the active
scheduled/manual Bicep publisher eligible to publish the added paths. Live
publication and testing remain held for separate approval; retaining Lab is
not authorization to start more Lab tests. Historical legacy deployment-job
durations informed selection, not fresh BAMI results or a speed guarantee.

## Checklist

- [x] Add exactly the three selected paths, retaining Lab and legacy fallback.
- [x] Validate configuration shape without duplicating its current membership.
- [x] Test group resolution and selector-only expansion with synthetic inputs.
- [x] Remove the repeated canary list from the README.
- [x] Preserve malformed-path, bundle, and Terraform selection safeguards.
- [x] Rerun the focused repository gate after the review feedback.

## Validation

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
skips. The tests exercise selection rules and selector-only expansion without
copying the live canary list. A separate check validates the checked-in
configuration without prescribing its membership. GitHub calls and the
component configuration read are mocked; no live runs or settings changed.

`git diff --check` passed. Publisher workflows, shared bundle/resolver code,
Terraform configuration, and repository sync are unchanged.

## Blockers or dependencies

No source blocker. Live publication and tests require separate approval.
