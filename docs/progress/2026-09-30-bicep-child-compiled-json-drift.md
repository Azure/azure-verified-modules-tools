# Bicep child compiled JSON drift

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Completed**: 2026-09-30
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Make checked-in `main.json` drift inspectable for every compiled Bicep module
scope, including nested children under `modules/`. `avm check convention` must
compare its own compiled output with the stored artifact, while `avm transform`
and `avm pre-commit` must discover and repair those same children. `avm pr-check`
must keep its non-writing drift mode. Reuse the exact-byte comparison between
the convention and transform engines and preserve source-less metadata-only
children. This is a deterministic local rule; no publication or cloud lookup
is part of this slice.

## Checklist

- [x] Compare compiled and stored bytes for root and all children with named
      missing/stale diagnostics, without reading linked artifacts.
- [x] Extend non-writing and writing transform scope discovery to `modules/`
      children and preserve the no-partial-write behavior.
- [x] Cover matching, stale, missing, BOM/newline, and metadata-only examples
      in unit and component tests.
- [x] Update the pinned static-coverage ledger and public help.
- [x] Independently review and address issues, run `./build.ps1 pre-commit`,
      commit, push, and update the existing review.

## Validation

Focused `./build.ps1 pre-commit -TestName @(
'Get-AvmBicepCompiledJsonDrift*', 'Invoke-AvmBicepTransform*',
'Bicep static convention checks*')` passed layout, lint, 19 unit tests, and
31 component tests. The tests exercise nested `modules/` children with
matching, stale and missing artifacts, byte-only BOM/newline drift, metadata-only
children, no writes in drift mode, successful repair, and no partial writes
when a nested compilation fails. The unfiltered gate and independent review
are complete. Independent code review found no significant issues. The final
unfiltered `./build.ps1 pre-commit` passed layout, lint, 1,928 unit tests
(nine skipped), and 961 component tests (none skipped). It reported 49
warnings from exercised negative-path tests. The pinned inventory's M:717
is now covered in convention as well as the transform step; the five other
convention families still fail closed. No registry workflow or remote
resource was changed.

## Blockers or dependencies

Publication status, child publishing allowlists, and the registry-literal
telemetry distinction remain separate fail-closed families. This slice does
not change metadata/source validation, test tiers, Terraform, registry CI,
releases, or deployed resources.
