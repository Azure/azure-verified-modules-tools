# Resolve analyzer informational findings

**Status**: complete
**Started**: 2026-09-23
**Updated**: 2026-09-23
**Branch**: `jaredfholgate-avm-authoring-upgrade-prompts`

## Outcome

Fix the informational PSScriptAnalyzer findings in the lint job without
disabling the rules or changing the PowerShell functions' output contracts.
Make future informational findings fail lint alongside warnings and errors.

## Checklist

- [x] Replace array wrappers that report `Object[]` instead of streamed values.
- [x] Name the two positional `Join-Path` arguments.
- [x] Reject informational analyzer findings in the lint task.
- [x] Validate zero findings and preserve output behavior with focused tests.
- [x] Run the local pre-commit gate; commit and push to the active branch.

## Validation

- The prior Ubuntu lint job emitted nine distinct informational findings:
  seven output-type/array-expression reports and two positional `Join-Path`
  reports. No analyzer rules were disabled.
- `./build.ps1 lint`: no findings.
- Focused Pester tests covering result formatting, process output, example
  selection, Terraform validation and module metadata: 119 passed.
- An uncommitted informational probe made lint fail as required. The probe was
  removed; the next lint run again reported no findings.
- `./build.ps1 pre-commit`: 1768 unit tests passed; 908 component tests passed
  and one skipped. Fixture warning messages did not fail the gate.

## Blockers or dependencies

None.
