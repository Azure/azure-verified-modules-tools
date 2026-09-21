# Catalog publication merge

**Status**: complete
**Started**: 2026-09-21
**Updated**: 2026-09-21
**Branch**: `jaredfholgate-workflow-debugging`

## Outcome

Catalog publication merges its generated changes using the existing AVM App
squash-merge process, matching the exact published head. The migration report
remains hash-validated workflow evidence, not a repository output. Existing
app-owned catalog branches lose report-only changes before merging.

## Checklist

- [x] Merge new and existing catalog changes, including retrying unchanged candidates.
- [x] Keep migration diagnostics in the build artifact and preserve row-loss checks.
- [x] Remove report changes from existing app-owned candidates without changing main's copy.
- [x] Cover successful publication, retries, merge failures, and artifact boundaries.
- [x] Update publication documentation.
- [x] Run the local gate, commit, and push.

## Validation

`.\build.ps1 pre-commit` passed: 1,620 unit tests and 847 component tests,
zero failures (nine unit skips and one component skip). Publication cases use
real local Git repositories with mocked GitHub responses. They cover new and
unchanged candidates, no-op publication, legacy report cleanup, retained main
content, rejected human/unrelated edits, merge errors, unmerged responses and
head mismatches. Artifact-only report hashes and row-retention checks remain
covered. Git cleanup handles Windows read-only object files.

The first CI run on the pull request failed on every operating system because
the merge fixtures mocked `Get-Command` for `gh` but not for `git`, so the
publisher's `git` lookup had no matching mock. The fixtures now mock both, and
`.\build.ps1 pre-commit` is green again with the same counts.

Fixed nested held-back arrays at the publisher call site so the final merge
allow-list uses actual file paths rather than a stringified array.

## Blockers or dependencies

No production workflow dispatch or merge is performed by this development slice.
The workflow uses the existing App permissions; it does not grant new access.
The internal Azure-Verified-Modules-Docs runbook should be updated to describe
automatic catalog merging and artifact-only diagnostics when this change lands.
