# Mapotf regression file URIs

**Status**: complete
**Started**: 2026-09-09
**Updated**: 2026-09-09
**Branch**: `jaredfholgate-fix-mapotf-errors`

## Outcome

Fix the Linux and macOS integration failures in
[#108](https://github.com/Azure/azure-verified-modules-tools/pull/108).
The regression fixture casts Unix filesystem paths to relative `System.Uri`
values, whose `AbsoluteUri` is empty. This produces invalid module sources
such as `git::?ref=...` before the released mapotf fix can be exercised.

Construct the fixture's URI with an explicit `file` scheme and empty host,
preserving escaped path characters and the existing commit/subdirectory syntax.
The mapotf pin and production implementation are unchanged.

## Checklist

- [x] Confirm the same malformed-source error in Linux and macOS job logs.
- [x] Reproduce the URI cast and explicit-scheme behavior with both path styles.
- [x] Correct the fixture and assert that the URI preserves its filesystem path.
- [x] Run focused integration coverage and the pre-commit gate.
- [x] Commit and push the correction to the existing review.

## Validation

- Reproduced the empty `AbsoluteUri` with `/tmp/source repo` and a macOS-style
  path. Explicit `UriBuilder` construction preserves those paths, Windows drive
  paths, spaces, and a literal `#`.
- Focused `.\build.ps1 integration`: all three Git module-source cases passed
  using the published mapotf 0.1.12 binary, including path round-tripping and
  idempotence.
- `.\build.ps1 pre-commit`: passed; the existing analyzer retry recovered from
  two transient crashes and reported 165 non-blocking warnings.
- Replacement cross-platform results are tracked in
  [the existing review's checks](https://github.com/Azure/azure-verified-modules-tools/pull/108/checks).

## Blockers or dependencies

None. The user owns merging and publishing; no production rerun is needed.
