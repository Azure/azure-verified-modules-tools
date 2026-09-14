# CODEOWNERS pending auto-merge guard

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-codeowners-sync`

## Outcome

Reject an existing candidate with GitHub auto-merge already enabled before a
plan-only run updates its head. Updating such a candidate could otherwise allow
GitHub to merge it independently of the script's explicit merge path. Preserve
that configuration for operator review rather than disabling it automatically.

## Checklist

- [x] Reject pending auto-merge in the shared candidate identity guard.
- [x] Cover the candidate metadata and the no-write plan-only failure path.
- [x] Run the local pre-commit gate and prepare the focused follow-up for publication.

## Validation

`.\build.ps1 -Tasks test-repository-management,pre-commit` passed: 242 focused
tests, 1,250 unit tests (8 skipped), and 33 component tests. Layout and lint
completed with the existing module warnings and no errors.

The generator, shared owners group, template, and initial exported CODEOWNERS
bytes are unchanged.

## Blockers and dependencies

The existing owner-access and compatibility rollout prerequisites still apply.
No production workflow, target synchronization, or configuration change is run.
