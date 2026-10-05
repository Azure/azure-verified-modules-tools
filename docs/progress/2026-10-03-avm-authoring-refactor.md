# Avm.Authoring maintainability refactor

**Status**: in-progress
**Started**: 2026-10-03
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Make `Avm.Authoring` easier to review and maintain without changing public
commands, parameters, result shapes or failure handling:

- Move repeated domain identifiers, pinned versions and rule baselines into a
  few packaged `Resources` configuration files loaded from the module base.
- Share repeated Bicep end-to-end safety checks (ownership tag, run id,
  context-restore failure detection) instead of copying them.
- Move the shipped Bicep convention checks into a packaged Pester suite under
  `Resources/bicep`, run by the existing `Invoke-AvmPesterSuite` adapter.
  Native Terraform tooling stays as it is.
- Remove pointless tests, speed up slow setup, and add useful edge cases to
  the integration fixtures. Report only measured timings.

No live Azure, cleanup or reaper, identity, authentication, release or
registry cutover work is in scope.

## Baseline

`./build.ps1 pre-commit` on `main` at the branch start (includes merge
`659ad4d`, #219), Pester 5.7.1, Windows:

| Task      | Elapsed | Result                     |
| --------- | ------- | -------------------------- |
| layout    | 0m09s   | pass                       |
| lint      | 1m56s   | pass                       |
| test      | 6m08s   | 2,854 passed, 9 skipped    |
| component | 5m43s   | 1,264 passed, 1 skipped    |
| total     | 13m56s  | pass                       |

Unit test case time sums to 286s of the 6m08s wall time, so per-file setup
dominates. `Invoke-Avm.Tests.ps1` spends about 40s outside its test cases.
The slowest component groups are resumable Terraform `avm init` (140s),
Terraform pre-commit/pr-check end to end (130s), and module catalog
transformations and publication (244s together).

## Checklist

- [x] Baseline the gate and find slow tests.
- [x] Fix the version-check opt-out (separate slice:
  `2026-10-03-terraform-scaffold-azapi-interfaces.md`).
- [x] Share the Bicep end-to-end safety checks (`2026-10-05-bicep-configuration.md`).
- [x] Move pinned versions, policy baselines and the `.e2eignore` allowlist to
  packaged configuration (`2026-10-05-bicep-configuration.md`).
- [x] Reduce repeated policy issue construction
  (`2026-10-05-bicep-policy-issue-construction.md`).
- [x] Move Bicep convention checks to a packaged Pester suite
  (`2026-10-05-bicep-convention-pester.md`).
- [x] Review help and comments ([slice](2026-10-05-help-and-comment-review.md)).
- [x] Prune redundant tests; extend integration fixtures ([record](2026-10-05-test-pruning-and-fixtures.md)).
- [ ] Final slice, as the user directed: reduce test run time, including safe
  parallel runs, with before and after timings for the full gate.
