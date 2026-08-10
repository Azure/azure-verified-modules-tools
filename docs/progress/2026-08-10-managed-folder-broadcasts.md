# Managed folder broadcasts

**Status**: complete
**Started**: 2026-08-10
**Updated**: 2026-08-10
**Branch**: `jaredfholgate-support-folder-sync`

## Outcome

Managed-file sources can place content under `<parent>/_all/` to broadcast it
into every existing immediate child of that target parent. `_all` requires a
named parent, is never copied literally when reserved, and does not create
missing target parents or child directories.

## Checklist

- [x] Reproduce the missing Terraform `_footer.md` failure.
- [x] Choose `_all` as the reserved broadcast directory.
- [x] Generalize expansion beyond `modules` and `examples`.
- [x] Preserve concrete-path, overlay, exclusion, drift, SHA, and mode behavior.
- [x] Cover arbitrary parents through unit and component tests.
- [x] Complete `./build.ps1 pre-commit`.
- [x] Keep dependent governance [PR #550](https://github.com/Azure/avm-terraform-governance/pull/550) draft until a compatible release exists.

## Validation

`./build.ps1 pre-commit`: 854 unit passed, 7 skipped, and 26 component
passed. Layout and lint completed with the repository warning baseline.

## Dependencies

Governance [PR #550](https://github.com/Azure/avm-terraform-governance/pull/550)
must merge only after tooling
[PR #43](https://github.com/Azure/azure-verified-modules-tools/pull/43)
is released and adopted by the governance sync.
