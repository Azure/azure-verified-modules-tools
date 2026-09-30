# BAMI branch plan-only preview

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Include BAMI-selected modules when manually previewing repository sync from
the trusted tools repository's feature branch with `plan_only=true`. Keep BAMI
apply runs restricted to `main`, and reject fork, tag, pull-request, scheduled,
or other non-manual branch contexts.

## Checklist

- [x] Share the BAMI run-context guard between the sync entry point and direct
      BAMI candidate identity preparation.
- [x] Cover allowed branch previews and rejected branch applies and untrusted
      contexts in unit and component tests.
- [x] Update the repository-sync operating guidance.
- [x] Pass `./build.ps1 pre-commit`, commit, and push this slice.

## Validation

Focused unit and component checks passed for a trusted manual branch preview
through Terraform planning and pre-commit, and direct BAMI identity planning
without apply. Forked, non-Actions, non-manual, pull-request, tag, and branch
apply contexts fail before repository work. `./build.ps1 pre-commit` passed
with 1,894 unit tests, 856 component tests, 9 platform skips, and 0 errors.
No live sync, Azure deployment, or protected environment was run for this
slice.

## Blockers or dependencies

A plan-only run cannot provision an absent BAMI identity or its validation
federation; those modules continue to report a pending identity instead of
publishing changes. Do not start a live sync or Azure operation as part of
this code slice.
