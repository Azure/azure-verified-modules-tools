# Bicep README provenance value regressions

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Completed**: 2026-10-01
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Exercise the private generated-comment provenance render with realistic
numeric, boolean, object, array, and Unicode values and authored descriptions
that contain full example frames, headings, HTML, and marker/template-like
strings. Verify stripping only producer-owned markers reproduces the normal
README bytes; changes outside those two marked comments remain stale.

## Checklist

- [x] Add positive and adversarial negative unit/component regressions using
      first-party JSON parameter conversion and authored lookalike content.
- [x] Run focused regression tests after the coordinator released the
      shared full-gate slot.
- [x] Run unfiltered `./build.ps1 pre-commit` for the test and qualified
      convention closure changes.

## Validation

Focused `./build.ps1 test -TestName
@('*Get-AvmBicepDocsExampleCommentDifferenceCount*',
'*Get-AvmBicepDocsExampleCommentProbe*')`: 14 passed, including
numeric/boolean/object/array and Unicode values from the real
`ConvertTo-AvmBicepDocsExampleParameter` producer. The test places a complete
lookalike frame, table-of-contents-like link, section headings, HTML
boundaries, and template/marker-like strings in authored content. Only the
actual producer-owned comment pair is marked. Removing its markers yields
byte-identical UTF-8 to the normal render; omitting the authored pair or
changing values, Unicode normalization, line endings, or private output
leaves the comparison stale. No production, MCR, or Azure call is part of
these focused tests.
The combined full gate passed layout/lint, 2,008 unit tests (nine skipped),
and 1,049 component tests (one skipped), with zero errors and 49 existing
negative-path warnings. An independent review of the closure delta found
no significant issues.

## Blockers or dependencies

None for this regression slice. The scoped public `machine:0.6.0` artifact
and full-registry comparison are recorded in
[README qualification](2026-10-01-bicep-current-registry-readme-qualification.md);
no other module restore or registry CI change is authorized.
