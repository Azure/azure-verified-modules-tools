# Re-enable routing/sync schedules

Status: complete
Started: 2026-09-23
Updated: 2026-09-23
Branch: jaredfholgate-reenable-routing-schedules

## Outcome

Step 3 of the "merge dispatch-only, dispatch what-if, then restore schedules"
sequence recorded in
[`2026-09-22-inert-workflow-validation.md`](2026-09-22-inert-workflow-validation.md).
All four what-if/live dispatch validations have now passed, including a
confirmed live module-list-sync run that opened and auto-merged
[Azure/bicep-registry-modules#7388](https://github.com/Azure/bicep-registry-modules/pull/7388).
This slice restores the four previously-commented schedules, and only those
schedules, so `Azure/bicep-registry-modules` PR #7378 (the pure-removal
follow-up in that repository) can merge last without leaving module PRs/issues
unrouted.

Restored `schedule:` triggers (GitHub Actions crons are UTC):

| Workflow | Cadence cron | Daily backstop cron |
| --- | --- | --- |
| `repository-management-pr-reviewer-routing.yml` | `7,22,37,52 * * * *` | `13 3 * * *` |
| `repository-management-issue-owner-routing.yml` | `9,24,39,54 * * * *` | `17 3 * * *` |
| `repository-management-workflow-failure-issues.yml` | `41 5 * * *` | n/a (single daily cron) |
| `repository-management-module-list-sync.yml` | n/a (single daily cron) | `13 6 * * *` |

`workflow_dispatch` remains available on all four with `what_if` still
defaulting to `true`, so a manually triggered run stays a dry run unless the
operator explicitly opts out. On a `schedule` trigger, `inputs.what_if`
evaluates to an empty string, and each work step already computes
`$whatIf = $env:WHAT_IF -eq 'true'`, which is `false` for an empty string, so
scheduled runs take the live path (not a no-op) without any further change.

### Lookback-window bug found and fixed before activation

The pr-reviewer-routing and issue-owner-routing workflows also read a
`updated_within_minutes` lookback from `inputs.updated_within_minutes`. On a
`schedule` trigger there are no `inputs`, so that env var is an empty string;
`[int]''` casts to `0`, and the candidate-fetch functions only apply the
lookback filter when `-gt 0`. Left as-is, every 15-minute cadence run would
silently become a full open-PR/open-issue sweep instead of only the intended
daily backstop cron. Fixed by passing `github.event_name` and
`github.event.schedule` into the run step via `env:` (not interpolated into
the `run:` body) and mapping explicitly:

| Workflow | Cadence cron -> lookback | Backstop cron -> lookback |
| --- | --- | --- |
| `repository-management-pr-reviewer-routing.yml` | `7,22,37,52 * * * *` -> 60 min | `13 3 * * *` -> 0 (full sweep) |
| `repository-management-issue-owner-routing.yml` | `9,24,39,54 * * * *` -> 60 min | `17 3 * * *` -> 0 (full sweep) |

`workflow_dispatch` still uses `inputs.updated_within_minutes` unchanged
(default `'60'`, `0` for an explicit full sweep). An unrecognized event or
schedule value throws explicitly rather than silently defaulting to a full
sweep. The 60-minute cadence lookback matches the original 4x-cadence design
decision for a 15-minute cron. `workflow-failure-issues` and
`module-list-sync` have no `updated_within_minutes` input, so they were not
affected by this bug.

## Checklist

- [x] Confirm no existing open PR/branch in `Azure/azure-verified-modules-tools`
      already restores these schedules.
- [x] Restore the two crons in `repository-management-pr-reviewer-routing.yml`.
- [x] Restore the two crons in `repository-management-issue-owner-routing.yml`.
- [x] Restore the one cron in `repository-management-workflow-failure-issues.yml`.
- [x] Restore the one cron in `repository-management-module-list-sync.yml`.
- [x] Update each workflow's header comment from "disabled, restore after
      validation" to the re-enabled design invariant.
- [x] Update the four `*.Tests.ps1` "workflow safety" contexts to assert
      `schedule` + `workflow_dispatch` (not `workflow_dispatch`-only) and to
      match the crons as `- cron: '...'` list entries.
- [x] Fix the schedule-vs-dispatch lookback-window bug in
      pr-reviewer-routing and issue-owner-routing (found on review) and add
      a regression test pinning the cron-to-lookback mapping for each.
- [x] Leave Terraform repository sync and every other workflow untouched.
- [x] Run targeted Pester for the four affected test files.
- [x] Run `./build.ps1 pre-commit`.

## Validation

- Targeted Pester (`ReviewerRouting.Tests.ps1`, `IssueOwnerRouting.Tests.ps1`,
  `WorkflowFailureIssues.Tests.ps1`, `ModuleListSync.Tests.ps1`): 121 passed,
  0 failed (after the lookback-window fix and its regression tests).
- `./build.ps1 pre-commit`: see commit for full counts.

## Notes for the reviewer

- No workflow was dispatched and no production settings were changed while
  producing this slice.
- `Azure/bicep-registry-modules#7378` should merge only after these schedules
  are live on `main` in this repository, per the design decision that routing
  must never run on `pull_request_target`/untrusted-fork triggers, and must
  not have a gap where no path exists to route PRs/issues.
