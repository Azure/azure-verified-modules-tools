# Pinned policy prerequisites in CI

**Status**: blocked
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Install the existing pinned PSRule dependencies in integration CI before real
copied-package policy acceptance. Runtime authoring commands remain non-installing.

## Evidence

[Run 37368558805](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37368558805)
on `e6f1e77` passed Ubuntu Test. Ubuntu AzAPI integration job `111959638137`
passed 138 cases and skipped one; two policy cases failed because PSRule 2.9.0
was absent. Local policy acceptance had used already-installed dependencies.

## Checklist

- [x] Add an opt-in pinned policy prerequisite group using the existing retry/cache path.
- [x] Enable it in integration CI, without expanding ordinary build prerequisites.
- [x] Test exact pins, installed-version reuse and workflow wiring.
- [x] Run the local gate and safe policy acceptance, and commit.
- [ ] Push with user-approved workflow-authorized authentication.

## Validation

- Pester 6.2.0 focused prerequisite/workflow checks: 13 passed.
- `build.ps1 integration -TestName 'Integration: packaged Bicep policy*'`: two
  passed against a copied build with real PSRule evaluation and the insecure
  transport negative.
- Pester 6.2.0 `build.ps1 pre-commit`: 3,006 unit passed / nine skipped,
  1,498 component passed / one skipped; layout and lint green.
- Existing retry and exact-installed-version behavior is reused; ordinary
  lint/test jobs do not install the policy modules. Runtime commands still give
  an actionable missing-dependency error rather than installing dependencies.

No broad local integration run, Azure operation or host-security change.

## Blocker

Commit `d3fac2a` is qualified locally. GitHub rejected its push because the
current OAuth App lacks `workflow` scope for `.github/workflows/ci.yml`; remote
remains `6e834e9`. The coordinator was notified to arrange user-approved
workflow-authorized authentication. No credential change, alternate-account
workaround, force push or rebase was attempted. Hosted confirmation remains
pending that push.
