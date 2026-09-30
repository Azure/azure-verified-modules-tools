# Repository sync candidate validation

**Status**: complete
**Started**: 2026-09-29
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

After Terraform repository sync changes a module, stage a local candidate and
run `avm pr-check` plus unit tests in an isolated job using its non-production
test identity. Publish the exact validated file tree only when both checks pass.
Plan-only validates without publishing. A manual plan-only switch defaults to
the checked-out authoring source and can instead select the published Gallery
release; scheduled apply continues using Gallery.

## Checklist

- [x] Stage changed candidates and capture the file tree without remote writes.
- [x] Run candidate checks in an isolated job with the module's test identity.
- [x] Publish only a candidate matching the validated file tree.
- [x] Preserve no-change and other repository-sync callers.
- [x] Cover failures, plan-only, identity selection, and workflow wiring with
      focused tests.
- [x] Run the local pre-commit gate, commit, and push this slice.

## Validation

`./build.ps1 pre-commit` succeeded on the combined branch (1,894 unit
tests passed, 9 platform skips, 842 component tests passed, 0 errors).
Focused cases exercised changed, unchanged, plan-only, check-failure,
moved-base, and matching-tree publication paths. A real local Git
archive/patch round trip recreated the same tree in a separate checkout.
`actionlint` passed for the edited workflow. The single conflict when
bringing the federation prerequisite from `main` into this branch was
resolved by preserving both sets of sync-script parameters; the complete
gate was repeated afterward. I did not start a sync workflow, approve an
environment, run Terraform apply, or change an Azure resource.

## Blockers or dependencies

The existing identity federation and a plan-visible `test_settings` output
were merged separately in
[Azure/azure-verified-modules-tools#197](https://github.com/Azure/azure-verified-modules-tools/pull/197).
A plan-only run cannot create its own federated credential: the first live
preview must follow a separately approved identity apply and verification
that the module's test identity can authenticate. BAMI main-branch safety
remains in force.
