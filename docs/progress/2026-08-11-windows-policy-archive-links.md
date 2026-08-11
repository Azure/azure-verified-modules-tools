# Windows policy archive links

Status: complete
Started: 2026-08-11
Completed: 2026-08-11
Branch: jaredfholgate-fix-check-failure-output

## Outcome

Make pinned policy bundles containing Git symlinks extract reliably on Windows without requiring Developer Mode or elevated symlink privileges.

## Checklist

- [x] Add path-safe managed extraction for tar archives on Windows.
- [x] Materialize in-archive symbolic and hard links as regular file copies.
- [x] Keep native tar extraction on non-Windows platforms.
- [x] Cover valid links and archive path traversal with unit tests.
- [x] Run `./build.ps1 pre-commit`.
- [x] Commit and push the slice.

## Validation

- `./build.ps1 pre-commit` passed: 885 unit tests and 26 component tests.
- The pinned `Azure/policy-library-avm` v1.0.0 archive extracted on Windows; both `common.utils.rego` links were regular files with matching content.

## Blockers or dependencies

- None.
