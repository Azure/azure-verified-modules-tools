# Native workflow and ownership assertions

**Status**: complete
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Replace workflow and CODEOWNERS custom checker families with independent
packaged Pester assertions, retaining strict path/UTF-8 preparation and source
locations. No caller interface or workflow-template migration belongs here.

## Checklist

- [x] Compare existing assertions and pinned upstream workflow/ownership requirements.
- [x] Migrate assertions and remove obsolete checker families.
- [x] Preserve native source-line diagnostics and execution completeness.
- [x] Exercise positive fixtures and existing mutation controls on Pester 5/6.
- [x] Run the full gate, commit, and push.

## Requirement map

Reference: `Azure/bicep-registry-modules@ca00e89a931f637f628503a3a625e7d487157496`,
`compliance/module.tests.ps1`, workflow and CODEOWNERS sections.

| Requirement | Native destination | Evidence |
| --- | --- | --- |
| Workflow file, environment and canonical paths | `Workflow.Tests.ps1` | Positive native counts; missing/mis-cased/linked files, malformed YAML, missing/wrong paths |
| Dispatch inputs and defaults | `Workflow.Tests.ps1` | Missing input, false/missing validation defaults, forbidden location default |
| Main-only push, exact ordered filters and initializer guard | `Workflow.Tests.ps1` | Wrong/missing branches; missing/extra/tag/schedule filters; ordering and missing/weakened guards |
| CODEOWNERS defaults, ownerless module tree, final overrides | `Ownership.Tests.ps1` | Valid five-rule fixture; missing/wrong defaults, per-module ownership and wrong overrides |
| Anchored non-module extras, unique patterns, source lines | `Ownership.Tests.ps1` | Accepted anchored extra; rejected broad/unanchored patterns, duplicates, precise source lines and invalid UTF-8 |

## Validation

The real native-only component control executes 20 workflow and 17 ownership
cases. Existing full-command mutation controls exercise the mappings above.
The caller rejects missing ownership test registration, even if all remaining
family tests report pass. Native diagnostics retain repository-relative versus
module-relative paths and the nearest data-driven source line.

Pester 6 focused execution exposed and corrected the automatic `$input`
variable collision, singleton-array unrolling and diagnostic-root differences.
Full Pester 6.2.0 `build.ps1 pre-commit`: 3,002 unit passed / nine skipped,
1,498 component passed / one skipped; layout and lint green. Pester 5.7.1
focused compatibility: 11 unit and 119 component passed / one skipped.
Observed full gate 10m56s is not an equivalent-work performance comparison.
No deployment, workflow dispatch, registration or cutover.
