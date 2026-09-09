# Fork-safe Terraform module workflow

**Status**: complete
**Started**: 2026-09-03
**Updated**: 2026-09-04
**Branch**: `jaredfholgate-fork-safe-terraform-workflow`

## Outcome

Split the reusable Terraform module workflow's PR gate into two paths. Branch
pull requests retain the authoritative credentialled `pr-check`; fork pull
requests run a separate credential-free `pr-check` using the synthetic token
fallback from PR #98. Unit tests run for both paths, while integration, example
discovery, and end-to-end tests remain restricted to trusted, non-fork runs.

> [!IMPORTANT]
> This workflow pull request must not merge until
> [PR #98](https://github.com/Azure/azure-verified-modules-tools/pull/98) has
> merged and the resulting `Avm.Authoring` release has been published to
> PSGallery. Merging earlier would make consuming module repositories invoke
> credential-free policy behavior that the published module does not support.

## Checklist

- [x] Restore the authoritative credentialled `pr-check` for branch pull requests.
- [x] Add a fork-only credential-free `pr-check-fork` job.
- [x] Keep unit tests available to forks and integration/e2e trusted-only.
- [x] Document both paths and the policy-needs-credential limitation.
- [x] Add isolated unit assertions for both PR-check job contracts.
- [x] Run `./build.ps1 pre-commit`.

## Validation

- `./build.ps1 pre-commit` - 1,033 unit tests passed, 8 skipped;
  29 component tests passed. Build completed with 0 errors. The lint task
  recovered from known transient PSScriptAnalyzer `NullReferenceException`
  retries and reported its existing warning set.

## Dependencies

- [PR #98](https://github.com/Azure/azure-verified-modules-tools/pull/98)
  must merge first.
- The `Avm.Authoring` release containing PR #98 must be published to PSGallery
  before this workflow pull request may merge.
