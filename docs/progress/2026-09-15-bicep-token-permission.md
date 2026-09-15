# Bicep Variables token permission

**Status**: complete
**Started**: 2026-09-15
**Updated**: 2026-09-15
**Branch**: `jaredfholgate-bicep-token-permission`

## Outcome

Correct the separate Bicep Variables token input to request only
`actions_variables: write` on `Azure/bicep-registry-modules`, retaining the
verified action pin. Keep the CODEOWNERS token, temporary lab-only
`TEST_BAMI_MODULE_PATHS` array, Terraform behavior, and all sync guards unchanged.

## Checklist

- [x] Correct the input and document the pinned generic-parser behavior.
- [x] Add exact token-input regression coverage and reject the old spelling.
- [x] Run the repository-management tests and required local gate.
- [x] Prepare the bounded fix for review.

## Validation

The regression-first run failed only the two permission assertions against the
old input. After correction:

- `.\build.ps1 test-repository-management`: 379 passed.
- `.\build.ps1 pre-commit`: 1,425 unit tests passed (8 skipped) and 117 component
  tests passed, including the unchanged CODEOWNERS and tenant-safety contracts.
- `actionlint`, parsed YAML token-scope checks, PowerShell parsing, new-regression
  formatting, and `git diff --check` passed.

The unchanged source lint completed with 162 warnings after its documented
transient retry. Full-file formatting has the same 54 line-diff entries as
committed main; no unrelated formatting was changed.

The parent independently verified the exact pinned parser with synthetic
inputs: `INPUT_PERMISSION-ACTIONS-VARIABLES=write` produces only
`actions_variables: write`; the old input produces the invalid `variables` key.
The action manifest omits the input, but the runner warns without discarding it.

## Blockers and dependencies

No code-only blocker. Live token minting, workflow dispatch, variable writes,
Azure access, and BAMI testing are outside this slice.
