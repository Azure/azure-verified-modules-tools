# Reusable Bicep module fixtures

**Status**: complete
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Curate Bicep module inputs beside the Terraform module fixtures rather than
maintaining an ecosystem-specific location for whole modules. Preserve focused
malformed/parser snapshots and mutate isolated copies for negative cases.

## Checklist

- [x] Add the independent storage policy fixture in the preceding policy slice.
- [x] Move the existing documentation module/child/e2e fixture without duplication.
- [x] Extract the existing Graph/Key Vault reference module and local helper.
- [x] Wire the existing real-compiler and documentation command tests.
- [x] Run focused safe integration tests and the ordinary gate.
- [x] Commit and push this slice.

## Validation

`.\build.ps1 integration -TestName @('Integration: Bicep docs scoped examples*',
'Integration: Bicep existing-resource references*')`: six passed, zero failed
or skipped. These execute real compilation and README rendering for scoped
examples, child modules, UDT constraints, discriminated unions, parameter
examples, and existing Graph/Key Vault references.

`.\build.ps1 pre-commit`: layout, lint, 3,010 unit passes (nine skips), and
1,458 component passes (one skip), zero failures. The documentation fixture's
six tracked source/snapshot files moved unchanged; no duplicate tree remains.
Tests compile/render only; no Terraform integration setup, Azure deployment,
host-security modification, or registry checkout is required.

## Blockers or dependencies

Independent of the pending metadata framework-boundary decision. Complete
native compliance package acceptance remains in the broader completion slice.
