# Shared native metadata validation

**Status**: complete
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Use one common metadata constraint implementation and meaningful packaged
Pester assertions for explicit Bicep and Terraform metadata validation.
Internal construction, prompts, initialization, and discovery use the same
schema/value primitives without recursively invoking Pester.

User approval: "Go with your recommendation, but ensure it is consistent with
Terraform, I don't want two separate sets of code / checks for the same file."

## Checklist

- [x] Share contextual metadata schemas between internal guards and native tests.
- [x] Run public file and InputObject validation through native Pester.
- [x] Keep Bicep source assertions distinct from shared JSON constraints.
- [x] Batch composition validation and preserve diagnostics and public contracts.
- [x] Demonstrate paired ecosystem positives/negatives and built-package behavior.
- [x] Run the full gate, commit, and push.

## Validation

- `.\build.ps1 test,component -TestName '*metadata*'` passed, including paired
  ecosystem failures, real native execution, internal guard parity, public
  file/InputObject routing and fail-closed framework controls.
- `.\build.ps1 pre-commit` passed layout and lint, 3,010 unit tests (nine
  skipped), and 1,478 component tests (one skipped). Zero failures.
- `.\build.ps1 build,integration -TestName 'Integration: packaged native metadata*'`
  passed five cases on the final source: ten native requirements execute from
  the copied package without registry utilities; missing/invalid metadata,
  missing required telemetry, and missing source description fail.

No cloud execution or registry cutover. The observed full gate was 9m25s;
different test sets prevent treating this as an equivalent-work CI comparison.

## Requirement map

| Previous check | Packaged native requirement | Evidence |
|---|---|---|
| Root/child JSON shape | `matches the packaged root or child schema` | Existing schema component matrix; paired ecosystem shape mutation |
| Canonical module kind | `identifies the requested module kind` | Paired taxonomy-for-resource mutation; Oracle component matrix |
| Ecosystem/family prefix markers | `uses the ecosystem and module-kind telemetry marker` | Paired wrong-marker mutation; historical-prefix component matrix |
| Primary prefix absent from history | `does not repeat the current telemetry prefix in its history` | Paired history mutation |
| Published/instrumented scope telemetry | `supplies telemetry when required for this scope` | Paired child requirement mutation; root requirement remains in the public JSON schema |
| Case-insensitive owners | `has unique owner handles ignoring case` | Paired duplicate-owner mutation and real-schema owner unit tests |
| Source casing/regular file | `uses a regular main.bicep with exact casing when source exists` | Existing source casing and directory component cases |
| Metadata-only source boundary | `includes main.bicep when version or compiled output exists` | Existing metadata-only child component cases |
| Literal source name and description | Separate `declares a literal source metadata ...` cases | Existing literal parser/component cases; independent package missing-description mutation |

The internal guard no longer contains separate imperative implementations of
kind, telemetry, history, or owner constraints. It evaluates the exact schemas
used by the named native cases. An invalid owner list now produces one diagnostic
for its uniqueness requirement rather than one diagnostic per duplicate.

Strict JSON decoding and filesystem read errors remain preparation failures.
The public result fields and issue codes/severities are unchanged. Empty scope
discovery and incomplete, skipped, failed-container or failed-setup native runs
cannot report success.

## Blockers or dependencies

Boundary approval received. Native convention migration is a separate
outstanding part of the overall completion record, including compiled
telemetry/metadata agreement. This slice does not claim that the remaining
registry compliance assertions have been migrated.
