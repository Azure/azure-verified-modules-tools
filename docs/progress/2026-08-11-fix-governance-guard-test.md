# Allow progress notes to name the archived governance repository

**Status**: complete
**Started**: 2026-08-11
**Updated**: 2026-08-11
**Branch**: `jaredfholgate-fix-governance-guard-test`

## Outcome

`Repository management migration layout.limits the retired governance
identifier to its inert exclusion and tests` failed on all three CI legs of
PR #61.

The guard runs `git grep` for the retired `avm-terraform-governance`
identifier across every tracked file and allows exactly two locations: the
inert exclusion entry in `Get-RepositoriesWhereAppInstalled.ps1` and the
`RepositoryDiscovery` tests that cover it. The canary rollout rings slice
added a third: `docs/progress/2026-08-11-canary-rollout-rings.md` records
that the issue-triage workflow originated in that repository before it was
archived.

The guard's purpose is to keep the identifier out of executable surfaces.
Completed progress slices are an append-only audit trail and cannot be
rewritten, so `docs/progress/*.md` is now allowed alongside the existing two
exceptions.

The failure reached `main` because the slice that introduced it was a
documentation-only commit, and the commit protocol lets those skip
`./build.ps1 pre-commit`. The guard greps documentation as well as code, so
that exemption does not hold for files it inspects.

## Checklist

- [x] Read the failing CI annotations rather than guessing at the cause.
- [x] Reproduce the failure locally with `git grep`.
- [x] Allow `docs/progress/*.md` in the guard's exception list.
- [x] Confirm the guard still rejects the identifier everywhere else.
- [x] `./build.ps1 pre-commit` green.

## Validation

`./build.ps1 pre-commit` — exit 0.

## Blockers or dependencies

None. PR #61 was merged with the failing test accepted as non-blocking; this
slice branches from the resulting `main`.
