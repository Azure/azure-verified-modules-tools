# Fork-safe Terraform module workflow

**Status**: complete
**Started**: 2026-09-03
**Updated**: 2026-09-03
**Branch**: `jaredfholgate-fork-safe-terraform-workflow`

## Outcome

Allow the reusable Terraform module workflow's static `pr-check` job to run for
pull requests from forks without Azure credentials. Keep integration,
example discovery, and end-to-end tests restricted to trusted, non-fork runs
with their existing Azure authentication.

> [!IMPORTANT]
> This workflow pull request must not merge until
> [PR #98](https://github.com/Azure/azure-verified-modules-tools/pull/98) has
> merged and the resulting `Avm.Authoring` release has been published to
> PSGallery. Merging earlier would make consuming module repositories invoke
> credential-free policy behavior that the published module does not support.

## Checklist

- [x] Make `pr-check` fork-safe and credential-free.
- [x] Preserve trusted credential handling for integration and end-to-end jobs.
- [x] Document the caller secret and trust-boundary behavior in the workflow.
- [x] Add isolated unit assertions for the `pr-check` job contract.
- [x] Run `./build.ps1 pre-commit`.

## Validation

- `./build.ps1 pre-commit` - 1,031 unit tests passed, 8 skipped;
  29 component tests passed. Build completed with 0 errors. The lint task
  recovered from two known transient PSScriptAnalyzer `NullReferenceException`
  retries and reported its existing warning set.

## Dependencies

- [PR #98](https://github.com/Azure/azure-verified-modules-tools/pull/98)
  must merge first.
- The `Avm.Authoring` release containing PR #98 must be published to PSGallery
  before this workflow pull request may merge.
