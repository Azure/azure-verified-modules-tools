# Sync label main reconciliation

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Merge current `main` into the telemetry branch without losing its independent
per-repository Prepare, Validate, and Publish chain. Carry forward the
tools-owned label catalog migration: neither workflow should call the retired
CSV downloader.

## Checklist

- [x] Resolve the dispatcher conflict while preserving branch-preview inputs,
      matrix isolation, and main's removal of the labels download.
- [x] Remove the obsolete download from the per-repository reusable workflow.
- [x] Verify workflow structure and the merged local gate without live sync.
- [x] Commit and push the conflict resolution on the current feature branch.

## Validation

`actionlint` passed both repository-sync workflows. The focused label-source
and candidate-workflow tests passed (6/6). `./build.ps1 test-tenant-terraform`
passed 11 mocked repository-sync and four BAMI identity plans. The merged
`./build.ps1 pre-commit` gate passed with 1,984 unit tests, nine platform
skips, 965 component tests, and no errors. No live sync or Azure operation
was started. While the gate ran, the separate BAMI-wide selection review
merged into `main`; integrate that newer main change separately.

## Blockers or dependencies

Current `main` includes
[Azure/azure-verified-modules-tools#200](https://github.com/Azure/azure-verified-modules-tools/pull/200),
which removed the CSV script and changed Terraform repository sync to read
the tools-owned labels JSON. The branch moved the old step into a reusable
workflow before that change merged. The BAMI plan summary from
[Azure/azure-verified-modules-tools#205](https://github.com/Azure/azure-verified-modules-tools/pull/205)
also merged, but its source files auto-merge cleanly. Do not dispatch a live
sync or modify unrelated BAMI rollout settings.
