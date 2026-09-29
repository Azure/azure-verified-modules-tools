# Fast Bicep canaries

**Status**: complete
**Started**: 2026-09-29
**Updated**: 2026-09-29
**Branch**: `jaredfholgate-fast-bicep-canaries`

## Outcome

Add Application Security Group, IP Group, and Route Table to the central Bicep
`testTenant` canary group, retaining DevTest Lab and the legacy default. Only
the canonical path selection changes; the eight-source/five-execution bundle,
identities, Terraform selections, and managed-file rings remain unchanged.

This is source-only preparation. Merging the selection makes the active
scheduled/manual Bicep publisher eligible to publish the added paths. Live
publication and testing remain held for separate approval; retaining Lab is
not authorization to start more Lab tests. Historical legacy deployment-job
durations informed selection, not fresh BAMI results or a speed guarantee.

## Checklist

- [x] Add exactly the three selected paths, retaining Lab and legacy fallback.
- [x] Assert the exact real-config JSON projection and selector-only expansion.
- [x] Preserve malformed-path, bundle, and Terraform selection safeguards.
- [x] Run the focused repository gate for source review.

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

Passed: layout, lint, 154 unit tests, and 17 component tests; zero failures.
The real central config produces exactly Lab plus the selected trio.
The mocked active-Lab transition writes only `TEST_BAMI_MODULE_PATHS`;
all five execution values stay unchanged. Existing malformed-path, complete
bundle, and Terraform canary membership/order checks pass.

`git diff --check` passed. Publisher workflows, shared bundle/resolver code,
Terraform configuration, and repository sync are unchanged. Tests use mocked
GitHub calls and offline fixture processes; no live runs or settings changed.

## Blockers or dependencies

No source blocker. Live publication and tests require separate approval.
