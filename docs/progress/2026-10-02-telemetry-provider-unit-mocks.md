# Telemetry provider unit-test mocks

**Status**: complete
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Keep existing provider-mocked unit tests isolated when telemetry moves from
modtm to AzAPI. Make this migration in shared tooling, not a module-only repair.

## Checklist

- [x] Reproduce a missing AzAPI mock after removing the standard modtm mock.
- [x] Add the replacement only to direct unit tests, preserving authored
      non-empty AzAPI mocks and rejecting ambiguous real-provider or delegated tests.
- [x] Verify a real provider-mocked Terraform test and second-pass stability.
- [x] Run the full local gate.

## Validation

The published Virtual WAN unit test mocks azurerm, random, and modtm but
not AzAPI, and its run uses `command = apply`. Adding an AzAPI telemetry
resource while only deleting its modtm mock would introduce an unmocked
provider. No such module test was run locally with Azure credentials.
The filesystem-only regression reproduced the missing mock. A real
provider-mocked fixture then showed why an empty replacement alone is not
enough: its generated subscription ID failed AzAPI's local resource-ID
validation. Standard mocks now include a full synthetic subscription ID.
The real MaPoTF regression passes its provider-mocked Terraform test
(one run passed, zero failed) and verifies unchanged bytes on the next
transform. The expanded focused suite passed 54 tests, including alias and
provider-mapping safeguards. All 21 real MaPoTF telemetry integration
cases passed with zero failures or skips. The full pre-commit gate passed
layout, lint with no findings, 2,644 unit tests (nine existing skips), and
1,287 component tests (one existing skip), with zero failures.

## Blockers or dependencies

None for the shared implementation. The separate
[candidate-preview slice](2026-10-02-tflint-class-candidates.md) owns remote
qualification. Virtual WAN is archived and excluded from preview selection.
The active Azure Monitor Windows Agent and AVD Insights patterns also have
standard empty telemetry-provider mocks covered by this change.
No deployment, protected approval, or module publication was performed.
