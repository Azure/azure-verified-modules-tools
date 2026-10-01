# Reviewer team identifier normalization

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-reviewer-team-normalization`

## Outcome

The shared review-state parser now reduces qualified `organization/team`
identifiers to bare team slugs. Both routing and post-write verification use
that normalized state, recognizing existing group requests without duplicate
requests or false verification failures. Bare slugs and the existing
name-fallback path remain supported; user identities are unchanged.

## Checklist

- [x] Diagnose the exact deployed parser and confirm successful group requests.
- [x] Check merged routing work and start a feature worktree from current main.
- [x] Normalize team slugs in the shared parser.
- [x] Cover qualified/bare slugs, verification, and repeat-request prevention.
- [x] Update related documentation and run the local pre-commit gate.
- [x] Prepare the validated slice for commit and publication.

## Validation

`.\build.ps1 pre-commit -TestName ...` passed layout, lint, 194 routing and
summary unit tests, and 114 shared-metadata component tests with no failures.
The regression cases use the actual GitHub CLI shape:
`{ __typename: "Team", name: "...", slug: "Azure/..." }`.
They cover qualified and bare identifiers, name fallback, case-insensitive
deduplication, declared team owners, owners-group fallback, post-write
verification, and a second pass that makes no edit.

Tests for genuinely absent reviewers and labels still fail verification.
The mocked API round trip returns a qualified slug and verifies a successful
first write followed by an already-routed result.

A read-only query of
[Azure/terraform-azure-avm-ptn-ephemeral-credential#83](https://github.com/Azure/terraform-azure-avm-ptn-ephemeral-credential/pull/83)
returned `Azure/azure-verified-modules-module-owners`; the corrected parser
recognized the existing group using the expected bare slug. No routing
write was required for this check.

`git diff --check` passed. The runtime fix changes only the shared parser's
two team-identifier assignments.

## Blockers or dependencies

No source blockers. The
[failed run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36896740669/job/110485518623)
reported 112 request failures across 60 repositories because qualified team
slugs did not match the expected bare values. Read-only REST and timeline
checks confirmed successful owners-group requests in the inspected cases.

No live rerun, reviewer write, permission change, workflow/token change, or
dependency change was performed. An operator-approved rerun after merge is
the remaining workflow check. The team routing documentation should also
note support for qualified team identifiers.
