# Candidate managed-file parity

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Prepare and validate repository-sync candidates against the same managed-file
repository ID and tooling configuration. Ensure a newly generated managed file
is present in the committed candidate even when a module's `.gitignore` would
otherwise omit it. Do not force-stage unrelated ignored files.

## Checklist

- [x] Pass the real module ID and checked-out managed-file configuration to
      the isolated drift check, restoring inherited settings afterward.
- [x] Stage only managed files reported as newly added by a passing pre-commit
      sync, including ignored generated files.
- [x] Cover grouped repositories, ignored-file safety, plan-only behavior,
      and exact-tree validation with focused tests.
- [x] Pass the local pre-commit gate, commit, and push the change.

## Validation

Focused candidate-identity and Git-staging tests passed. The component tests
proved a managed script inside an ignored `scripts` directory enters the
candidate index while an unrelated ignored `.tfvars` file does not. They also
exercised plan-only candidate preparation without publishing. The full
`./build.ps1 pre-commit` gate passed with 1,956 unit tests, nine platform skips,
941 component tests, and no failures. No live sync or Azure operation ran.

## Blockers or dependencies

The cancelled [fleet preview](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36749306675)
showed five managed-file drift failures during candidate validation. An
offline replay of the staged ALZ management module found that the validator's
generic `repository` checkout selects the wrong file group. Its candidate
also omits a managed skill script because the module's `.gitignore` excludes
`scripts`; a normal `git add --all` cannot include the generated file. A
Windows replay additionally differs on the managed executable's Git mode,
which cannot establish a Linux runner defect. No new live run is authorized.
