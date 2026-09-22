# Inert workflow validation consolidation

Status: complete
Started: 2026-09-22
Updated: 2026-09-22
Branch: jaredfholgate-avm-reviewer-issue-routing

## Outcome

Consolidate the temporary PR-reviewer-routing validation split back into the
four-slice routing pull request. All four workflows must be inert when merged:
`workflow_dispatch` is their only trigger, `what_if` defaults to `true`, and
no schedule-dependent expression remains.

The intended sequence is:

1. Merge the four workflows while they are dispatch-only.
2. Dispatch each workflow with `what_if: true` and review its live output.
3. Open one follow-up pull request containing only trigger-block changes to
   restore all four schedules.

## Checklist

- [x] Close the redundant split pull request while retaining its branch.
- [x] Fold the validated PR-reviewer-routing workflow changes into this branch.
- [x] Disable all four schedules and preserve their cron values in comments.
- [x] Map dispatch inputs directly and keep `what_if` defaulted to `true`.
- [x] Extend all four workflow guard contexts for the inert-merge contract.
- [x] Run targeted tests.
- [x] Run `./build.ps1 pre-commit`.
- [x] Commit and push the consolidated changes.

## Validation

- Workflow safety contexts: 20 passed, 0 failed.
- `./build.ps1 pre-commit`: 1,613 unit tests passed, 9 skipped, 0 failed;
  903 component tests passed, 1 skipped, 0 failed.
- Static verification found no active `schedule`, `pull_request`,
  `pull_request_target`, `issues`, or `workflow_run` trigger in the four
  workflows and no `github.event.schedule` reference.
