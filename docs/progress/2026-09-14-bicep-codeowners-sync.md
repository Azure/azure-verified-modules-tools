# Bicep CODEOWNERS synchronization

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-codeowners-sync`

## Outcome

Add scheduled and manual AVM App automation that generates top-level module ownership
from the official Bicep resource, pattern, and utility indexes and synchronizes
only `Azure/bicep-registry-modules/.github/CODEOWNERS`. Retain tooling ownership
and the final governance-test and e2e-ignore overrides. Use one stable app-owned
branch and pull request, with narrowly validated unattended bypass merging.
Manual plans open or update the candidate without merging; the separate local
export performs no remote mutations. Static ownership and the automation header
come from a reviewed template.

[Operator documentation](../bicep-codeowners-sync.md) describes setup, modes,
the daily four-hour schedule offset by two hours from repository sync, and the
fail-closed safeguards.

## Checklist

- [x] Inspect repository instructions, existing automation, and current ownership.
- [x] Coordinate the generated rule contract with the Bicep compatibility work.
- [x] Implement deterministic top-level ownership and fail-closed CSV handling.
- [x] Implement app authentication, exact-change guards, and stable synchronization.
- [x] Add the scheduled/manual workflow and operator setup documentation.
- [x] Cover generation, idempotence, failures, and merge guards with offline tests.
- [x] Export the initial template-backed snapshot for the Bicep prerequisite.
- [x] Run the focused repository-management tests and local pre-commit gate.
- [x] Prepare the implementation and validated handoff for feature-branch publication.

## Validation

`.\build.ps1 test-repository-management` passed all 240 focused tests.
`.\build.ps1 pre-commit` passed layout, lint, 1,248 unit tests (8 skipped), and
33 component tests, including the JSON request-file and cleanup cases. The
unchanged module lint required its existing transient analyzer retry and
reported 200 pre-existing warnings; there were no build errors.

Development used only local mocked tests and live read-only inspection; no
target synchronization, target writes, workflow dispatches, ruleset edits, or
other production configuration changes were performed by this slice.

The local export from official index commit
`6142d822b65db7013818d717519a562e67ce664f` has 267 top-level rows, no child rows,
237 rows with individuals plus the shared team, and 30 team-only rows. Its Git
blob is `e08f89ef2d4fb3b059bafc6ac32eb60c6003f5f3`; the parent session owns adding
it to the Bicep change. No target writes were made by this slice.

## Blockers and dependencies

- [Azure/bicep-registry-modules#7343](https://github.com/Azure/bicep-registry-modules/pull/7343)
  must land before automatic merging; the script enforces this prerequisite.
- Operators must install the existing AVM App on the target repository and
  explicitly approve its bypass in every applicable ruleset. The automation
  must fail rather than change rulesets, self-approve, or use another identity.
- The initial source snapshot includes owners that GitHub reports as unknown or
  lacking write access. Operators must resolve the diagnostics or correct the
  CSVs; both plan and merge modes surface these errors without dropping owners.
