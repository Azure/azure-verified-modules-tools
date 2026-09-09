# Exclude tooling repositories from sync discovery

**Status**: complete
**Started**: 2026-09-09
**Updated**: 2026-09-09
**Branch**: `jaredfholgate-terraform-state-migration`

## Outcome

Exclude `policy-library-avm`, `mapotf`, and `azure-verified-modules-tools` before
module naming validation. These tooling repositories are installed on the AVM
GitHub App but are not module repositories and should not emit discovery errors.

## Checklist

- [x] Extend the existing built-in skip list.
- [x] Assert tooling exclusions produce no warning or issue artifact.
- [x] Retain naming validation for unexpected repositories and normal modules.
- [x] Complete the local gate for the existing feature branch.

## Validation

- `.\build.ps1 test-repository-management`: 79 passed.
- `.\build.ps1 pre-commit`: unit and component suites passed. Existing
  analyzer warnings remain; the negative discovery test intentionally reports
  an unexpected repository.
- Six tooling-name cases cover the three requested names and their uppercase
  equivalents. Each produces neither warnings nor an issue artifact and still
  discovers the normal module fixture. Unexpected names retain error diagnostics.
- [Plan-only branch run 34346945719](https://github.com/Azure/azure-verified-modules-tools/actions/runs/34346945719)
  at `d98854c94b0ded26c2107a17a455df080790966c` confirms all three tooling
  repositories are skipped through the exclusion list, with no naming-error
  annotations. TME OIDC login, backend initialization, and Terraform plan pass.
- Attempts 1 and 2 failed later during MaPoTF authoring transforms because
  GitHub returned HTTP 500 while downloading AzAPI 2.12.0. One failed-job retry
  hit the same download failure on a different example. No code was changed to
  mask the external error; no apply ran. The earlier complete TME canary remains
  recorded in `2026-09-09-example-repo-tme-canary.md`.
- [Attempt 3](https://github.com/Azure/azure-verified-modules-tools/actions/runs/34346945719/attempts/3)
  succeeded at the same tested commit without further code changes. Logs
  confirm TME backend initialization, `plan_only=true`, four additions, zero
  changes/destroys, no Terraform apply, and authoring pre-commit with no changes.
  Project synchronization remained skipped. The download error is no longer
  a blocker to this canary.

## Blockers or dependencies

No Azure or GitHub configuration changes; scheduled behavior changes only when
the reviewed workflow code is merged.

The exclusions and full plan-only canary are complete. Final state migration
and cutover still require separate approval and a fresh copy under a writer freeze.
