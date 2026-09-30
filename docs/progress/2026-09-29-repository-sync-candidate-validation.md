# Repository sync candidate validation

**Status**: complete
**Started**: 2026-09-29
**Updated**: 2026-09-29
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

`./build.ps1 pre-commit` succeeded (0 errors; 834 component tests passed)
after targeted unit and component cases exercised changed, unchanged,
plan-only, check-failure, moved-base, and matching-tree publication paths.
A real local Git archive/patch round trip recreated the same tree in a
separate checkout. `actionlint` passed for the edited workflow. No sync
workflow, protected environment, Terraform apply, or Azure resource was run
for this slice.

## Blockers or dependencies

The existing identity federation and a plan-visible `test_settings` output
are being added separately in
[Azure/azure-verified-modules-tools#197](https://github.com/Azure/azure-verified-modules-tools/pull/197).
A plan-only run cannot create its own federated credential: the first live
preview must follow its merge and a separately approved identity apply.
That review's checks pass, but its branch protection still requires an
approving review. BAMI main-branch safety remains in force.
