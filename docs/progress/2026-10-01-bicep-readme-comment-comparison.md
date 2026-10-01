# Bicep README JSON-example comment comparison

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Accept missing pairs of generated JSON-example grouping comments in README
drift mode without accepting any other changed bytes. Keep generation
unchanged, the current-registry README parity family fail-closed, and the
registry's existing CI untouched.

## Evidence and comparison boundary

The pinned registry commit
`5c123604fa1da88e3d98e2acb01f4b8a8ea5b4c2` has five JSON parameter
examples in the Vault README, with JSON summaries at lines 77, 176, 543,
1128, and 1341. The file has Git blob
`427057a4dc54ea16daa70e3f05d5a379b7b43319` and SHA-256
`72BEFB145543D707BA849143ECCB8D4B17EFE2B09385156E6A5CC1B7060D8E01`.
Its first example already contains both grouping comments (lines 84 and 88);
only the remaining four examples lack both generated comments. Eight missing
lines are therefore a fact about this checked-in snapshot, **not** a
four-pair rule in the renderer.

`ConvertTo-AvmBicepDocsExampleParameter` emits a required/non-required comment
pair only when the source example has required and optional parameters. The
fixed Scriban template places that JSON in a labeled `via JSON parameters file`
fence under `## Usage examples` and `### Example ...`, with the exact
deployment-parameters schema. It requires the adjacent Bicep module and
Bicep-parameters frames, with exactly one of each format per example. It
checks sequential example headings against the renderer's table of contents
and scans through authored subheadings rather than treating them as example
boundaries: an authored lookalike block cannot receive the exception. The comparator
identifies those complete generated pairs and aligns each entire generated
line against the tracked UTF-8 text using ordinal comparison. It skips a
pair only when **both** comments are absent; a partially missing pair or
any changed prose, Bicep source, JSON value, output, other comment, code
fence, encoding, or line ending remains `avm.bicep.docs-stale`. The diagnostic
states the derived number of omitted lines. Normal `avm docs` writes the
full renderer output.
This generic local comparison rule does not expand the independently specified
full-registry qualification exception beyond the observed eight Vault lines.

The historical HCI README-only correction is preserved in session artifact
`hci-readme-version-correction.md`, not in this repository. Read-only,
immutable GitHub retrieval verified the old pinned README Git blob
`74313d1e7fd5783f15bcb996291e571ee84194e4` and SHA-256
`C6FD140F63C2473724A316AC18E260479104AC9A724B88EE9D08F5C7D3997EF5`:
line 595 documents `machine:0.4.1`. Pinned `main.bicep` Git blob
`d5f00262b862cac01270017bdb519fc75e3bf8fc` and SHA-256
`405DBDD1A53BEE7FCDDA89C0AA7510ED2B184D9652D941821EB80D879D377FAB`
invoke `machine:0.6.0` on line 105. No OCI artifact was queried or qualified.
Registry main at `dd8842c373ca793bac99037a19f0d68023e9b63d` already
contains that one-line correction via
[Azure/bicep-registry-modules#7430](https://github.com/Azure/bicep-registry-modules/pull/7430):
README blob `b7b23761e0708dc48858263ce7aa6d57f75fb632`, SHA-256
`390B2DD76984C9787BAB0FF1670D86EC080731B387908F16698EFB7FA0749A24`,
line 595 `machine:0.6.0`; source blob and hash are unchanged. No duplicate
upstream patch is needed. The historical offline build could not resolve
`machine:0.6.0`; the earlier cache recheck used a noncanonical nested path,
so it does not establish cache absence. An authoritative OCI qualification
and a complete current-head render are still outstanding.

## Checklist

- [x] Identify the shared README drift comparison and the precise generated
      comment block from verified pinned inputs.
- [x] Cover only missing complete generated comment pairs, with positive and
      adversarial negative tests for prose, code, types, examples, outputs,
      render failures and source-less documents.
- [x] Record the pinned HCI source/README mismatch as a historical session
      artifact and verify that its correction already merged upstream.
- [x] Run focused checks, request the coordinated full-gate slot, run
      `./build.ps1 pre-commit`, then commit and push to the existing review.

## Validation

Focused `./build.ps1 test -TestName
'*Get-AvmBicepDocsExampleCommentDifferenceCount*'`: eight passed.
Focused `./build.ps1 component -TestName @('*warns only for missing generated
JSON*','*retains render failures and source-less*')`: two passed. Full
`./build.ps1 component -TestName '*Component: Bicep docs source rendering*'`:
28 passed before the follow-up change. An independent read-only review
found no significant issues in the original comparator; the later
authored-lookalike regression prompted a narrowly scoped follow-up review.
That review found a second false positive: a description could insert
`### Appendix` between an authored lookalike and the actual renderer frame,
splitting the uniqueness scan. A new regression reproduced the incorrect
warning. The tightened heading/table-of-contents guard now rejects that
case, a forged numbered example heading, and an extra `## Parameters`
heading; the eight focused unit cases and two affected component cases
pass. The first unfiltered pre-commit gate passed (5 tasks, zero errors,
49 warnings, 11m30s) before this review-driven fix. The final unfiltered
gate after the fix passed layout, lint, 2,001 unit tests (nine skipped),
and 1,047 component tests (one skipped): five tasks, zero errors,
49 existing negative-path warnings, 10m16s.
Standalone `./build.ps1 lint` passed after a known transient analyzer
retry; `./build.ps1 layout` also passed.
The coordinator released the gate slot after the metadata and test-support
slices. No live MCR, Azure, or catalog lookups in this slice.

## Blockers or dependencies

There is no outstanding blocker for this comparison slice. Independently,
current-head README parity remains
blocked by the unverified published OCI dependency for the HCI example
and lack of a complete current-head render, not by the historical version
reference already fixed upstream. A passing local check must not be
treated as full-registry qualification. Authoritative machine bytes would
require separate consent for read-only HTTPS
`GET https://mcr.microsoft.com/v2/bicep/avm/res/hybrid-compute/machine/manifests/0.6.0`
and only its manifest-descriptor blob URLs under the same repository, with
digest verification. No MCR query, restore, Azure operation, or registry
CI change was performed in this slice; later qualification is separately
authorized only for this exact public module.
