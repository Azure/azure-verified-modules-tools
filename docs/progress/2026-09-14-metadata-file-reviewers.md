# Metadata file reviewers

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-metadata-file-reviewers`

## Outcome

Keep every root and child `metadata.json` file owned only by
`@Azure/azure-verified-modules-engineering-owners` in tools-generated Terraform
and Bicep CODEOWNERS. The exact rule is the final rule in both templates:

```text
metadata.json @Azure/azure-verified-modules-engineering-owners
```

Existing required-code-owner-review settings and the already-authorized AVM
App bypass remain unchanged. This slice changes generated ownership, not live
repository permissions or fleet state.

## Checklist

- [x] Inspect both generators, Bicep compatibility validation, and repository
      protection settings.
- [x] Add the final metadata rule to both templates.
- [x] Restrict old Bicep static content to base and old-candidate compatibility.
- [x] Cover root, child, unrelated files, final-rule precedence, and compatibility
      with offline regressions.
- [x] Run the repository build entrypoints.
- [x] Prepare the validated metadata-only changes for separate review against
      the Terraform generator repair branch.

## Validation

- `.\build.ps1 test-repository-management` with `AVM_OFFLINE=1`: 281 passed,
  none failed, skipped, or not run. Includes 52 new policy regressions.
- `.\build.ps1 pre-commit` with `AVM_OFFLINE=1`: 1,327 unit tests and 93
  component tests passed; eight existing unit skips, no failed or unexecuted
  tests, and no container or teardown failures. Persisted NUnit results report
  zero errors and failures. Existing module analyzer warnings remain.
- The first full gate reproduced the dependency's known Terraform test-teardown
  failure. This branch then adopted the dependency owner's existing CI fix
  `f12ca3e`; the final full gate above passed. No CI fix was authored here.
- `git diff --check` passed. Files remain UTF-8 without BOM with LF endings.

## Dependencies and rollout

- Depends on the Terraform generator repair in
  [#119](https://github.com/Azure/azure-verified-modules-tools/pull/119).
  It remained open after validation at `f12ca3e`; the separate review targets
  `jaredfholgate-terraform-code-owners` so its diff contains only this policy.
  Retarget to `main` after the dependency merges.
- Metadata implementation stays in
  [#113](https://github.com/Azure/azure-verified-modules-tools/pull/113), without
  this policy change.
- The actual Bicep registry change is owned by the separate registry session.
  Both implementations use the same final rule.
- Confirm required code owner reviews, engineering-team eligibility, and the
  existing AVM App bypass before an authorized rollout. CODEOWNERS alone does
  not enforce approval. Adopt the generated rules on target default branches
  before relying on them. No live settings changes or sync runs were performed.
- Checked-in Terraform settings retain an active default-branch ruleset with
  `require_code_owner_review = true`, the existing AVM App integration in
  `pull_request` bypass mode, and engineering-team `push` access. Those
  settings are unchanged; actual fleet state was not queried.
- The registry session reports active main-branch code owner review enforcement
  and visible engineering-team write access. Its API read did not expose bypass
  actors, so existing App bypass details still need operator verification.
- Document the operational review and initial-backfill procedure in
  `Azure-Verified-Modules-Docs` as part of the coordinated rollout.

## Blockers

None identified.
