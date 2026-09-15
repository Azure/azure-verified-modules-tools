# Metadata policy integration

**Status**: complete
**Started**: 2026-09-15
**Updated**: 2026-09-15
**Branch**: `jaredfholgate-metadata-file-reviewers`

## Outcome

Integrate current `main` into the existing metadata ownership review
[#120](https://github.com/Azure/azure-verified-modules-tools/pull/120) after
the Terraform generator repair was squash-merged in
[#119](https://github.com/Azure/azure-verified-modules-tools/pull/119).
Preserve both generators, the existing CI fixes, and the final engineering-only
`metadata.json` rule without importing the separate metadata implementation.

## Checklist

- [x] Confirm the existing review targets `main` and the worktree is clean.
- [x] Merge `origin/main` locally without rebasing or force-pushing.
- [x] Resolve only metadata policy integration and preserve root, child, and
      deep metadata coverage.
- [x] Run `.\build.ps1 pre-commit` and inspect persisted results.
- [x] Record the rollout restriction and prepare the validated merge for
      publication to the existing review.

## Validation

- Integrated `origin/main` at `306345e163ac8d14bde8287f62ae8ee6eb91b82f`.
  The five conflicts were overlaps with the squash-merged generator repair.
  Resolved generator and test code matches the previously validated policy
  branch exactly; both generators and the dependency owner's CI fixes remain.
- `.\build.ps1 pre-commit` with `AVM_OFFLINE=1`: 1,327 unit and 93 component
  tests passed; eight existing unit skips, no failed or unexecuted tests, and no
  container or teardown failures. Persisted NUnit results report zero errors
  and failures. Existing analyzer warnings remain.
- `git diff --check` passed. There are no module, workflow, repository-setting,
  or Terraform generator implementation changes relative to the integrated
  `main`; the original metadata policy diff is preserved.
- Hosted CI must run afresh on the integration commit after publication.
  Its exact-head results are recorded on the existing review rather than
  inferred from the previous head's checks.

## Rollout dependencies

- [Azure/bicep-registry-modules#7349](https://github.com/Azure/bicep-registry-modules/pull/7349)
  must land before the metadata-protecting Bicep generator may run. Bicep
  `main`'s old governance tests reject the additional final metadata rule.
- Resume Bicep Sync only after both that registry change and
  [#120](https://github.com/Azure/azure-verified-modules-tools/pull/120) merge,
  with fresh full checks passing on their final heads. The old tools static
  guard also rejects target content after the metadata rule is adopted.
- Keep Bicep Sync disabled throughout that incompatible interval, starting
  before [#113](https://github.com/Azure/azure-verified-modules-tools/pull/113)
  merges. That separate change intentionally removes the old enable-variable
  gate; setting the old variable to false is not sufficient afterward.
- Workflow disablement and re-enablement are operator-approved rollout actions,
  not part of this integration. No remote merge, production sync, permission
  change, or settings change is authorized here.
- Preserve required code owner reviews and the existing AVM App bypass. No
  additional bypass or credential is introduced.

## Blockers

None identified.
