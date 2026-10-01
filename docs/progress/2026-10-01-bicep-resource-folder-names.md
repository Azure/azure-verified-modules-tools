# Bicep resource folder naming parity

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Completed**: 2026-10-01
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Resolve the resource-folder naming gap against the pinned registry
assertion M:157 without inventing a linguistic singularization rule.
The legacy assertion transforms the *folder's own name* to its
lowercase/hyphen form and reduces both names before comparing them;
it never reads the resource type or another source of singular names.
The current first-party lowercase/hyphen syntax check is at least as
strict for this observable behavior, and plural module names are
allowed. A read-only current-registry scan found one real
double-hyphen child, `configuration--customdnssuffix`; keep that
existing name valid rather than adding a hardcoded module exception.
Verify those boundaries with root and child fixtures, then
leave only unqualified README regeneration fail-closed.

## Checklist

- [x] Verify the pinned assertion, current first-party rule, and real
      registry resource-folder names without a network/cloud lookup.
- [x] Test lowercase singular/plural folders, existing repeated hyphens,
      and uppercase, camel-case and underscore names in root and child scopes.
- [x] Independently review the coverage claim; update the ledger with
      the actual, not assumed, assertion semantics.
- [x] Run the unfiltered `./build.ps1 pre-commit`, commit, push and
      update the existing review.

## Validation

An offline checkout at `5c123604fa1da88e3d98e2acb01f4b8a8ea5b4c2`
contains 524 resource folders with `main.bicep`. One existing child
uses repeated hyphens; the revised rule accepts all 524 without a
per-module exception. It still rejects uppercase, camel-case and
underscores. Focused component fixtures passed for 114 cases (one
Windows-only skip). Independent review confirmed coverage of the
*actual* M:157 assertion, not grammatical singularization; the new
rule is stricter than M:157 for some otherwise unrepresented names.
The unfiltered `./build.ps1 pre-commit` passed layout, clean lint,
1,974 unit tests (nine skipped) and 1,044 component tests (one skipped).
The 49 warnings come from existing negative-path tests. No live
MCR/Azure call or registry CI change was made.

## Blockers or dependencies

No authoritative inflection/singular-name source is present in M:157.
If a future rule must enforce grammatical singularization, it needs
a separate design and accepted exceptions; this slice covers existing
static CI behavior only. README byte parity remains uncovered.
