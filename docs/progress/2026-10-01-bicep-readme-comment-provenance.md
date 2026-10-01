# Bicep README generated-comment provenance

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Replace Markdown-layout inference in the narrow JSON-example comment exception
with renderer/model provenance. A private, non-writing Bicep docs render will
mark only the grouping comments supplied in generated example JSON values.
Remove those markers in memory and require the result to match the normal
render byte-for-byte before accepting any complete omitted comment pairs.
Do not change generated README bytes, public result shape, Terraform, registry
CI, or the fail-closed README coverage family.

## Evidence and boundary

The prior comparator on this branch checks numbered headings, a table of
contents, and three adjacent rendered formats. A description controlled by
module authors can itself contain convincing Markdown, so those checks cannot
prove that a comment belongs to the template output. The reviewer's
authored-heading regression fixed one concrete false positive but did not
establish provenance. Treat the earlier committed comparison as transitional
until this follow-up is validated and pushed.

The actual template interpolates `example_data.JsonParameters` into the
generated JSON fence. The custom example value is built by
`ConvertTo-AvmBicepDocsExampleParameter`, which inserts the required and
non-required comments. Only those two lines will receive private,
unpredictable markers in a second render. Authored descriptions come from
the Bicep model, not these custom values, so copied headings, full example
frames, fences, and prose remain unmarked. A half-present marker pair,
repeated markers, unexpected content, or any other byte difference must
keep the README stale.
An alias for a child example that is not rendered in a particular README
has neither marker in the private output and is ignored; exactly one
marker appearing is an invalid, fail-closed private render.

## Checklist

- [x] Record comment provenance from generated example values without
      changing normal renderer output or public result contracts.
- [x] Cover approved missing-pair cases and adversarial authored descriptions,
      malformed pairs, unrelated prose/value/output changes, and probe errors.
- [x] Run focused tests and the unfiltered `./build.ps1 pre-commit` after
      coordinator approval, then commit/push to the existing review.
- [x] Keep M:651 fail-closed until separately qualified published dependency
      and current-registry README rendering succeed.

## Validation

Focused `./build.ps1 test -TestName
@('*Get-AvmBicepDocsExampleCommentDifferenceCount*',
'*Get-AvmBicepDocsExampleCommentProbe*')`: 13 passed.
Focused `./build.ps1 component -TestName @('*warns only for missing generated
JSON*','*retains render failures and source-less*','*distinguishes generated
comments from authored*','*fails closed with named diagnostics when the
private*')`: four passed. The full Bicep docs component selector passed
30 cases. `./build.ps1 lint` passed after renaming the pure in-memory
probe helper to an approved read-only verb; `./build.ps1 layout` passed.
An independent read-only review found that unrendered child aliases
initially forced valid omissions to be stale. The focused child-alias
regression now ignores a wholly absent alias but fails when only one
of its markers appears. The private-render mock reads the actual temporary
custom-value file and interpolates its marked JSON field; unit tests verify
the original model values are unchanged. A focused component check also
verified that both renders pass `--no-restore` in offline mode and clean
their temporary custom-value files. Final unfiltered `./build.ps1 pre-commit`
passed layout, lint, 2,006 unit tests (nine skipped) and 1,049 component
tests (one skipped): five tasks, zero errors, 49 existing negative-path
warnings, 10m36s. Real current-registry qualification is a separate
pending step.

## Blockers or dependencies

There is no outstanding blocker for this provenance slice. Public MCR
consent is limited to the separate `machine:0.6.0` qualification step;
no MCR/Azure call was made for this code change.
